import Darwin
import Foundation

struct DiskEntry: Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    var bytes: Int64
    var isPartial: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct DiskScanResult: Sendable {
    let root: URL
    let entries: [DiskEntry]
    let isPartial: Bool

    var children: [URL: [DiskEntry]] = [:]
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

}

enum DiskScanner {
    /// Physical allocation observed below a folder, restricted to its volume.
    /// APFS clones may share blocks, so this is an estimate of usage.
    static func scan(_ root: URL, onInventory: @escaping @Sendable (DiskScanResult) -> Void = { _ in },
                     onDirectory: @escaping @Sendable (String) -> Void = { _ in }) async throws -> DiskScanResult {
        let worker = Task.detached(priority: .utility) {
            try FolderWalk().scan(root, onInventory: onInventory, onDirectory: onDirectory)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

private final class FolderWalk {
    private let deadline = DispatchTime.now() + .seconds(15)
    private var remainingItems = 200_000
    private var rootDevice: dev_t = 0
    private var countedLinks = Set<ino_t>()
    private let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    func scan(_ url: URL, onInventory: (DiskScanResult) -> Void, onDirectory: (String) -> Void) throws -> DiskScanResult {
        try Task.checkCancellation()
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let root = url.standardizedFileURL
        let fd = open(root.path, directoryFlags)
        guard fd >= 0 else { throw posixError(url: root) }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError(url: root) }
        rootDevice = info.st_dev
        var entries: [DiskEntry] = []
        var partial = false
        // Inventory the first level before entering any one large subtree.
        let readAll = try readChildren(fd, root: root) { name in
            guard entries.count < 16_384 else { return false }
            guard let label = String(validatingUTF8: name) else {
                partial = true
                return true
            }
            var child = stat()
            let known = fstatat(fd, name, &child, AT_SYMLINK_NOFOLLOW) == 0
            let directory = known && isDirectory(child)
            entries.append(DiskEntry(
                url: root.appendingPathComponent(label, isDirectory: directory),
                isDirectory: directory,
                bytes: known ? allocatedBytes(child) : 0,
                isPartial: !known || child.st_dev != rootDevice
            ))
            return true
        }

        var inventory = entries
        for i in inventory.indices where inventory[i].isDirectory { inventory[i].isPartial = true }
        onInventory(DiskScanResult(root: root, entries: sorted(inventory), isPartial: true))

        // Keep only the first generation of completed subfolders, within a shared cap.
        var children: [URL: [DiskEntry]] = [:]
        var slots = 2048
        var nextUpdate = DispatchTime.now()
        for index in entries.indices where entries[index].isDirectory && !entries[index].isPartial {
            try Task.checkCancellation()
            if DispatchTime.now() >= nextUpdate && withinBudget {
                onDirectory(entries[index].name)
                nextUpdate = .now() + .milliseconds(180)
            }
            var bytes = entries[index].bytes
            let folder = entries[index].url
            var immediate: [DiskEntry] = []
            var fits = slots > 0
            let complete = try measureDirectory(at: entries[index].name, parent: fd, depth: 1, bytes: &bytes) { name, directory, size in
                guard fits else { return }
                guard immediate.count < slots, let label = String(validatingUTF8: name) else {
                    fits = false
                    return
                }
                immediate.append(DiskEntry(url: folder.appendingPathComponent(label, isDirectory: directory),
                                           isDirectory: directory, bytes: size, isPartial: false))
            }
            if complete && fits {
                children[folder] = sorted(immediate)
                slots -= max(1, immediate.count)
            }
            entries[index].bytes = bytes
            entries[index].isPartial = !complete
        }
        try Task.checkCancellation()
        return DiskScanResult(
            root: root, entries: sorted(entries),
            isPartial: partial || !readAll || entries.contains(where: { $0.isPartial }), children: children
        )
    }

    private func sorted(_ entries: [DiskEntry]) -> [DiskEntry] {
        entries.sorted {
            if $0.bytes == $1.bytes { return $0.name < $1.name }
            return $0.bytes > $1.bytes
        }
    }

    private var withinBudget: Bool {
        remainingItems > 0 && DispatchTime.now() < deadline
    }

    private func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func allocatedBytes(_ info: stat) -> Int64 {
        guard info.st_dev == rootDevice else { return 0 }
        if !isDirectory(info), info.st_nlink > 1, !countedLinks.insert(info.st_ino).inserted {
            return 0
        }
        return info.st_blocks * 512
    }

    private func measureDirectory(
        at name: UnsafePointer<CChar>, parent: Int32, depth: Int, bytes: inout Int64,
        childMeasured: ((UnsafePointer<CChar>, Bool, Int64) -> Void)? = nil
    ) throws -> Bool {
        guard depth <= 64, withinBudget else { return false }
        // Resolve each child from its open parent, including after a rename.
        let fd = openat(parent, name, directoryFlags)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var directory = stat()
        guard fstat(fd, &directory) == 0, directory.st_dev == rootDevice else { return false }
        var complete = true
        let readAll = try readChildren(fd) { childName in
            var child = stat()
            guard fstatat(fd, childName, &child, AT_SYMLINK_NOFOLLOW) == 0,
                  child.st_dev == rootDevice else {
                complete = false
                return true
            }
            let before = bytes
            bytes += allocatedBytes(child)
            let directory = isDirectory(child)
            if directory,
               try !measureDirectory(at: childName, parent: fd, depth: depth + 1, bytes: &bytes) {
                complete = false
            }
            childMeasured?(childName, directory, bytes - before)
            return true
        }
        return complete && readAll
    }

    /// fdopendir owns its descriptor. Keep the caller's descriptor for openat.
    private func readChildren(
        _ fd: Int32, root: URL? = nil, visit: (UnsafePointer<CChar>) throws -> Bool
    ) throws -> Bool {
        let copy = dup(fd)
        guard copy >= 0 else {
            if let root = root { throw posixError(url: root) }
            return false
        }
        guard let stream = fdopendir(copy) else {
            let code = errno
            close(copy)
            if let root = root { throw posixError(url: root, code: code) }
            return false
        }
        defer { closedir(stream) }
        while withinBudget {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0, let root = root { throw posixError(url: root) }
                return errno == 0
            }
            let keepReading = try withUnsafePointer(to: &entry.pointee.d_name) { storage in
                try storage.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { name in
                    if strcmp(name, ".") == 0 || strcmp(name, "..") == 0 {
                        return true
                    }
                    remainingItems -= 1
                    return try visit(name)
                }
            }
            if !keepReading { return false }
        }
        return false
    }

    private func posixError(url: URL, code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
