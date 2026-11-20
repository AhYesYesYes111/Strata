import Darwin
import Foundation

struct DiskEntry: Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    var bytes: Int64
    var isPartial: Bool
    var tileColorIndex: Int? = nil

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct DiskScanResult: Sendable {
    let root: URL
    let entries: [DiskEntry]
    let isPartial: Bool
    var children: [URL: [DiskEntry]] = [:]
    var pendingDirectories = 0
    var sequence = 0
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
}

enum DiskScanner {
    static let startupRoot = URL(fileURLWithPath: "/", isDirectory: true)
    static let startupData = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)

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

    static func scan(_ root: URL, wholeDisk: Bool = false,
                     onInventory: @escaping @Sendable (DiskScanResult) -> Void = { _ in },
                     onDirectory: @escaping @Sendable (String) -> Void = { _ in }) async throws -> DiskScanResult {
        let worker = Task.detached(priority: .utility) {
            try FolderWalk(root: root, wholeDisk: wholeDisk).scan(onInventory: onInventory, onDirectory: onDirectory)
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
    let isSystem: Bool
    let childCacheIndex: Int?
    let bytesBeforeChild: Int64

    init?(fd: Int32, isSystem: Bool = false, expected: FileIdentity? = nil,
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
        self.isSystem = isSystem
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

    init(index: Int, frame: DirectoryFrame, bytes: Int64) {
        self.index = index
        self.frames = [frame]
        self.bytes = bytes
    }
}

private final class FolderWalk {
    private let root: URL
    private let wholeDisk: Bool
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

    init(root: URL, wholeDisk: Bool) {
        self.root = root.standardizedFileURL
        self.wholeDisk = wholeDisk
        self.deadline = .now() + .seconds(wholeDisk ? 180 : 15)
        self.remaining = wholeDisk ? 6_000_000 : 200_000
    }

    func scan(onInventory: (DiskScanResult) -> Void, onDirectory: (String) -> Void) throws -> DiskScanResult {
        try Task.checkCancellation()
        guard root.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        var rootInfo = stat()
        let rootFD = open(root.path, flags)
        guard rootFD >= 0 else { throw posixError() }
        guard fstat(rootFD, &rootInfo) == 0 else {
            let failure = posixError()
            close(rootFD)
            throw failure
        }
        guard let rootFrame = DirectoryFrame(fd: rootFD, isSystem: root.path == "/System") else { throw posixError() }
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
                                              isSystem: entry.url.path == "/System", expected: identities[index]) {
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
                    task.immediate?[i].bytes = task.bytes - frame.bytesBeforeChild
                }
                task.frames.removeLast()
                continue
            }
            withName(item) { name in
                if wholeDisk && frame.isSystem && strcmp(name, "Volumes") == 0 { return }
                var info = stat()
                guard fstatat(frame.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { task.partial = true; return }
                guard devices.contains(info.st_dev) else {
                    if !wholeDisk { task.partial = true }
                    return
                }
                let folder = isDirectory(info)
                let before = task.bytes
                task.bytes += allocated(info)
                var cacheIndex: Int?
                if task.frames.count == 1, task.immediate != nil {
                    if cacheSlots > 0, let label = String(validatingUTF8: name) {
                        cacheSlots -= 1
                        cacheIndex = task.immediate?.count
                        let url = entries[task.index].url.appendingPathComponent(label, isDirectory: folder)
                        task.immediate?.append(DiskEntry(url: url, isDirectory: folder, bytes: task.bytes - before, isPartial: false))
                    } else {
                        task.immediate = nil
                    }
                }
                guard folder else { return }
                if task.frames.count < 64,
                   let child = DirectoryFrame(fd: openat(frame.fd, name, flags), expected: FileIdentity(info),
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
