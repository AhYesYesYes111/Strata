import Darwin
import Foundation
import System

// Foundation path standardization can consult the filesystem to resolve links.
private func lexicalPath(_ url: URL) -> String { FilePath(url.path).lexicallyNormalized().string }

struct DiskEntry: Identifiable, Sendable, Codable {
    let url: URL
    let isDirectory: Bool
    var bytes: Int64
    var isPartial: Bool
    var tileColorIndex: Int? = nil
    var requiresSelection = false

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct DiskScanResult: Sendable, Codable {
    let root: URL
    let entries: [DiskEntry]
    let isPartial: Bool
    var children: [URL: [DiskEntry]] = [:]
    var independentChildSizes: Bool? = true
    var pendingDirectories = 0
    var sequence = 0
    var measuredAt: Date?
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
}

/// Decide from the parent listing alone. Even a metadata query inside a privacy
/// boundary can cause a macOS access dialog before POSIX returns an error.
struct DiskScanPrivacy: Sendable {
    enum Context { case ordinary, home, library, applicationSupport, serviceStorage }
    private static let musicServices: Set<String> = [
        "com.apple.music", "com.apple.itunes", "com.apple.itunescloud", "com.apple.itunescloudd",
        "com.apple.amplibraryagent", "com.apple.ampartworkagent", "com.apple.medialibraryservice"
    ]
    let currentHome: String

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        currentHome = Self.logicalPath(lexicalPath(home)).lowercased()
    }

    // APFS exposes one home at both paths, including when chosen directly.
    private static func logicalPath(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        if path.caseInsensitiveCompare(data) == .orderedSame { return "/" }
        return path.lowercased().hasPrefix(data.lowercased() + "/") ? String(path.dropFirst(data.count)) : path
    }

    func context(for path: String) -> Context {
        let path = Self.logicalPath(path).lowercased()
        if isHome(path) { return .home }
        let library = "/library"
        if path.hasSuffix(library), isHome(String(path.dropLast(library.count))) { return .library }
        let support = "/library/application support"
        if path.hasSuffix(support), isHome(String(path.dropLast(support.count))) { return .applicationSupport }
        for suffix in ["/library/caches", "/library/httpstorages"] where path.hasSuffix(suffix) {
            if isHome(String(path.dropLast(suffix.count))) { return .serviceStorage }
        }
        return .ordinary
    }

    private func isHome(_ path: String) -> Bool {
        path == currentHome || path == "/private/var/root" || path == "/var/root" ||
            (path.hasPrefix("/users/") && path != "/users/shared" && !path.dropFirst("/users/".count).contains("/"))
    }

    private func isMusicBoundary(_ name: String, in context: Context) -> Bool {
        if name.hasSuffix(".musiclibrary") || name.hasSuffix(".tvlibrary") || name.hasSuffix(".videoslibrary") { return true }
        switch context {
        case .home: return name == "music"
        case .library, .applicationSupport:
            return name == "music" || name == "itunes" || name == "medialibrary" || Self.musicServices.contains(name)
        case .serviceStorage: return Self.musicServices.contains(name)
        case .ordinary: return false
        }
    }

    func isBoundary(_ name: String, in context: Context) -> Bool {
        let name = name.lowercased()
        if isMusicBoundary(name, in: context) { return true }
        // A Photos library can be renamed or moved outside Pictures.
        if name.hasSuffix(".photoslibrary") || name.hasSuffix(".photolibrary") ||
            name.hasSuffix(".aplibrary") { return true }
        switch context {
        case .home:
            return ["desktop", "documents", "downloads", "pictures", "movies", ".trash"].contains(name)
        case .library:
            return ["containers", "group containers", "daemon containers", "cloudstorage", "mobile documents",
                    "mail", "messages", "safari", "calendars", "reminders", "homekit", "photos", "cookies",
                    "suggestions", "personalizationportrait", "sharing", "biome", "identityservices"].contains(name)
        case .applicationSupport:
            return ["addressbook", "callhistorydb", "callhistorytransactions", "mobilesync",
                    "com.apple.tcc", "knowledge", "fileprovider"].contains(name)
        case .ordinary, .serviceStorage: return false
        }
    }

    func needsSelection(_ url: URL, selectedFolder: URL?, musicOnly: Bool = false) -> Bool {
        let path = Self.logicalPath(lexicalPath(url))
        let selection = selectedFolder.map { Self.logicalPath(lexicalPath($0)) }
        var parent = ""
        for part in path.split(separator: "/") {
            let name = String(part)
            let child = parent + "/" + name
            let context = context(for: parent)
            if musicOnly ? isMusicBoundary(name.lowercased(), in: context) : isBoundary(name, in: context) {
                // Selecting an enclosing directory does not authorize additional
                // protected roots below it. Selecting a particular subtree does.
                guard let selection, selection == child || selection.hasPrefix(child + "/"),
                      path == selection || path.hasPrefix(selection + "/") else { return true }
            }
            parent = child
        }
        return false
    }

    func pickerStart(for requested: URL) -> URL {
        var directory = requested
        while needsSelection(directory, selectedFolder: nil, musicOnly: true) {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }
}

enum DiskScanAccessError: Error { case selectFolder }

enum DiskScanner {
    static let startupRoot = URL(fileURLWithPath: "/", isDirectory: true)
    static let startupData = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)

    static func directoryURL(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        return URL(fileURLWithPath: lexicalPath(url), isDirectory: true)
    }

    /// Follow startup firmlinks in the unified namespace once. Mount containers lead
    /// back to the Data tree, mounted disk images or unrelated storage.
    static func skipsStartupEntry(parent: String, name: String) -> Bool {
        if parent == "/System" { return name == "Volumes" }
        guard parent == "/" else { return false }
        switch name {
        case "Volumes", "dev", "home", ".vol", ".file", ".resolve", ".nofollow": return true
        default: return false
        }
    }

    static func scan(_ root: URL, wholeDisk: Bool = false, selectedFolder: URL? = nil,
                     privacy: DiskScanPrivacy = DiskScanPrivacy(),
                     onInventory: @escaping @Sendable (DiskScanResult) -> Void = { _ in },
                     onDirectory: @escaping @Sendable (String) -> Void = { _ in }) async throws -> DiskScanResult {
        let worker = Task.detached(priority: .utility) {
            guard !privacy.needsSelection(root, selectedFolder: selectedFolder) else { throw DiskScanAccessError.selectFolder }
            return try FolderWalk(root: root, wholeDisk: wholeDisk, privacy: privacy).scan(onInventory: onInventory, onDirectory: onDirectory)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
    init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
}

/// Owns one directory descriptor. Child opens stay relative to the verified parent.
private final class DirectoryFrame {
    let stream: UnsafeMutablePointer<DIR>
    let fd: Int32
    let url: URL
    let isSystem: Bool
    let privacyContext: DiskScanPrivacy.Context
    let childCacheIndex: Int?
    let bytesBeforeChild: Int64

    init?(fd: Int32, url: URL, privacy: DiskScanPrivacy, expected: FileIdentity? = nil,
          childCacheIndex: Int? = nil, bytesBeforeChild: Int64 = 0) {
        guard fd >= 0 else { return nil }
        var actual = stat()
        guard fstat(fd, &actual) == 0,
              expected == nil || expected == FileIdentity(actual),
              let stream = fdopendir(fd) else {
            close(fd)
            return nil
        }
        self.fd = fd
        self.stream = stream
        self.url = url
        self.isSystem = url.path == "/System"
        self.privacyContext = privacy.context(for: url.path)
        self.childCacheIndex = childCacheIndex
        self.bytesBeforeChild = bytesBeforeChild
    }
    deinit { closedir(stream) }
}

private final class DirectoryWalk {
    let index: Int
    var frames: [DirectoryFrame]
    var bytes: Int64
    var partial = false
    var immediate: [DiskEntry]? = []
    var localBytes: Int64 = 0
    var localLinks = Set<FileIdentity>()

    init(index: Int, frame: DirectoryFrame, bytes: Int64) {
        self.index = index
        self.frames = [frame]
        self.bytes = bytes
    }
}

private final class FolderWalk {
    private let root: URL
    private let wholeDisk: Bool
    private let privacy: DiskScanPrivacy
    private let deadline: DispatchTime
    private var remaining: Int
    private var devices = Set<dev_t>()
    private var countedLinks = Set<FileIdentity>()
    private var entries: [DiskEntry] = []
    private var identities: [Int: FileIdentity] = [:]
    private var children: [URL: [DiskEntry]] = [:]
    private var cacheSlots = 2048
    private var partial = false
    private var sequence = 0
    private let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    init(root: URL, wholeDisk: Bool, privacy: DiskScanPrivacy) {
        self.privacy = privacy
        self.root = DiskScanner.directoryURL(root)
        self.wholeDisk = wholeDisk
        self.deadline = .now() + .seconds(wholeDisk ? 180 : 15)
        self.remaining = wholeDisk ? 6_000_000 : 200_000
    }

    func scan(onInventory: (DiskScanResult) -> Void, onDirectory: (String) -> Void) throws -> DiskScanResult {
        try Task.checkCancellation()
        guard root.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        var rootInfo = stat()
        // openat below never follows links. Protect intermediate components of
        // the initial path as well (including a directory replaced since drill-down).
        var path = root.path
        for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp"), ("/etc", "/private/etc")] {
            if path == alias || path.hasPrefix(alias + "/") {
                path = target + path.dropFirst(alias.count)
                break
            }
        }
        let rootFD = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard rootFD >= 0 else { throw posixError() }
        guard fstat(rootFD, &rootInfo) == 0 else {
            let failure = posixError()
            close(rootFD)
            throw failure
        }
        guard let rootFrame = DirectoryFrame(fd: rootFD, url: root, privacy: privacy) else { throw posixError() }
        devices.insert(rootInfo.st_dev)
        if wholeDisk {
            for url in [DiskScanner.startupRoot, DiskScanner.startupData] {
                var volume = stat()
                if lstat(url.path, &volume) == 0 { devices.insert(volume.st_dev) }
            }
        }
        var queue = try inventory(rootFrame)
        // Start the independent large branches together and let small ones finish beside them.
        let priority = ["Users": 0, "Applications": 1, "Library": 2, "System": 3, "opt": 4, "private": 5, "usr": 6]
        if wholeDisk && root.path == "/" {
            queue.sort { (priority[entries[$0].name, default: 7], entries[$0].name) <
                         (priority[entries[$1].name, default: 7], entries[$1].name) }
        }
        // A tile keeps its color as its live size changes its rank.
        let paletteOrder = queue + entries.indices.filter { identities[$0] == nil }
        for (color, index) in paletteOrder.enumerated() { entries[index].tileColorIndex = color }
        onInventory(snapshot(pending: queue.count, finished: false))
        var next = 0
        var active: [DirectoryWalk] = []
        var nextUpdate = DispatchTime.now()
        while (next < queue.count || !active.isEmpty) && withinBudget {
            try Task.checkCancellation()
            while active.count < 8 && next < queue.count {
                let index = queue[next]
                next += 1
                let entry = entries[index]
                if let frame = DirectoryFrame(fd: openat(rootFrame.fd, entry.name, flags),
                                              url: entry.url, privacy: privacy, expected: identities[index]) {
                    active.append(DirectoryWalk(index: index, frame: frame, bytes: entry.bytes))
                }
            }
            for task in active where withinBudget {
                try advance(task)
                entries[task.index].bytes = task.bytes
                if task.frames.isEmpty {
                    entries[task.index].isPartial = task.partial
                    if !task.partial, let immediate = task.immediate, !immediate.isEmpty || cacheSlots > 0 {
                        if immediate.isEmpty { cacheSlots -= 1 }
                        children[entries[task.index].url] = sorted(immediate)
                    }
                }
            }
            active.removeAll(where: { $0.frames.isEmpty })
            if DispatchTime.now() >= nextUpdate {
                if let first = active.first { onDirectory(entries[first.index].name) }
                onInventory(snapshot(pending: active.count + queue.count - next, finished: false))
                nextUpdate = .now() + .milliseconds(350)
            }
        }
        try Task.checkCancellation()
        return snapshot(pending: 0, finished: true)
    }

    private func inventory(_ directory: DirectoryFrame) throws -> [Int] {
        var queue: [Int] = []
        while withinBudget && entries.count < 16_384 {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(directory.stream) else {
                if errno != 0 { throw posixError() }
                return queue
            }
            withName(item) { name in
                guard let label = String(validatingUTF8: name) else { partial = true; return }
                if wholeDisk && DiskScanner.skipsStartupEntry(parent: root.path, name: label) { return }
                if privacy.isBoundary(label, in: directory.privacyContext) {
                    entries.append(DiskEntry(url: root.appendingPathComponent(label, isDirectory: true),
                                             isDirectory: true, bytes: 0, isPartial: true, requiresSelection: true))
                    return
                }
                var info = stat()
                let known = fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
                if wholeDisk && known && !devices.contains(info.st_dev) { return }
                let folder = known && isDirectory(info)
                // At the startup root aliases such as /tmp and /var are represented by /private.
                if wholeDisk && root.path == "/" && known && (info.st_mode & S_IFMT) == S_IFLNK { return }
                let sameVolume = known && devices.contains(info.st_dev)
                if folder && sameVolume {
                    queue.append(entries.count)
                    identities[entries.count] = FileIdentity(info)
                }
                entries.append(DiskEntry(url: root.appendingPathComponent(label, isDirectory: folder),
                                         isDirectory: folder, bytes: sameVolume ? allocated(info) : 0,
                                         isPartial: !sameVolume || folder))
            }
        }
        partial = true
        return queue
    }

    /// Each top-level row advances by a small quantum before its siblings get a turn.
    private func advance(_ task: DirectoryWalk) throws {
        for _ in 0..<512 {
            try Task.checkCancellation()
            guard withinBudget, let frame = task.frames.last else { return }
            errno = 0
            guard let item = readdir(frame.stream) else {
                if errno != 0 { task.partial = true }
                if let i = frame.childCacheIndex, task.immediate != nil {
                    task.immediate?[i].bytes = task.localBytes - frame.bytesBeforeChild
                }
                task.frames.removeLast()
                continue
            }
            withName(item) { name in
                if wholeDisk && frame.isSystem && strcmp(name, "Volumes") == 0 { return }
                // d_type comes from the parent directory, without opening the child.
                let type = Int32(item.pointee.d_type)
                if type == DT_DIR || type == DT_UNKNOWN || frame.privacyContext != .ordinary {
                    guard let label = String(validatingUTF8: name) else { task.partial = true; return }
                    if privacy.isBoundary(label, in: frame.privacyContext) { task.partial = true; return }
                }
                var info = stat()
                guard fstatat(frame.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { task.partial = true; return }
                guard devices.contains(info.st_dev) else {
                    if !wholeDisk { task.partial = true }
                    return
                }
                let folder = isDirectory(info)
                let before = task.localBytes
                task.bytes += allocated(info)
                if task.immediate != nil {
                    // Child snapshots measure this folder independently of its siblings.
                    // Repeated links *within* the folder may be attributed differently by
                    // its standalone scanner. Let drill-down run that scan in this case.
                    if !folder && info.st_nlink > 1 && !task.localLinks.insert(FileIdentity(info)).inserted {
                        task.immediate = nil
                    } else {
                        task.localBytes += info.st_blocks * 512
                    }
                }
                var cacheIndex: Int?
                if task.frames.count == 1, task.immediate != nil {
                    if cacheSlots > 0, let label = String(validatingUTF8: name) {
                        cacheSlots -= 1
                        cacheIndex = task.immediate?.count
                        let url = entries[task.index].url.appendingPathComponent(label, isDirectory: folder)
                        task.immediate?.append(DiskEntry(url: url, isDirectory: folder, bytes: task.localBytes - before, isPartial: false))
                    } else {
                        task.immediate = nil
                    }
                }
                guard folder else { return }
                if task.frames.count < 64, let label = String(validatingUTF8: name),
                   let child = DirectoryFrame(fd: openat(frame.fd, name, flags),
                                              url: frame.url.appendingPathComponent(label, isDirectory: true),
                                              privacy: privacy, expected: FileIdentity(info),
                                              childCacheIndex: cacheIndex, bytesBeforeChild: before) {
                    task.frames.append(child)
                } else { task.partial = true }
            }
        }
    }

    private var withinBudget: Bool { remaining > 0 && DispatchTime.now() < deadline }

    private func withName(_ item: UnsafeMutablePointer<dirent>, _ visit: (UnsafePointer<CChar>) -> Void) {
        withUnsafePointer(to: &item.pointee.d_name) { storage in
            storage.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { name in
                if strcmp(name, ".") != 0 && strcmp(name, "..") != 0 { remaining -= 1; visit(name) }
            }
        }
    }

    private func isDirectory(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFDIR }

    private func allocated(_ info: stat) -> Int64 {
        if !isDirectory(info), info.st_nlink > 1, !countedLinks.insert(FileIdentity(info)).inserted { return 0 }
        return info.st_blocks * 512
    }

    private func sorted(_ list: [DiskEntry]) -> [DiskEntry] {
        list.sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
    }

    private func snapshot(pending: Int, finished: Bool) -> DiskScanResult {
        sequence += 1
        return DiskScanResult(root: root, entries: sorted(entries),
                              isPartial: !finished || partial || entries.contains(where: \.isPartial),
                              children: finished ? children : [:], pendingDirectories: pending, sequence: sequence)
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: root.path])
    }
}
