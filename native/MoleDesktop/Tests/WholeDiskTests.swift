import Darwin
import Foundation

private final class InventoryLog: @unchecked Sendable {
    // The worker invokes inventory callbacks serially; the test reads after awaiting it.
    var updates: [DiskScanResult] = []
}

@main struct WholeDiskTests {
    @MainActor static func main() async throws {
        let model = DiskModel()
        model.startIfNeeded()
        precondition(model.location?.path == "/" && model.wholeDisk)
        model.cancel() // Test the entry point without walking personal data.

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let names = ["Users", "Applications"]
        let bytes = Data(repeating: 0x41, count: 4096)
        for name in names {
            let branch = folder.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: branch, withIntermediateDirectories: true)
            for index in 0..<680 {
                try bytes.write(to: branch.appendingPathComponent("f-\(index)"))
            }
        }
        let target = folder.appendingPathComponent("Users/f-0")
        try fm.linkItem(at: target, to: folder.appendingPathComponent("Applications/shared"))
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("Users/back").path, withDestinationPath: folder.path)
        for (parent, name) in [("/", "Volumes"), ("/", "dev"), ("/System", "Volumes")] {
            precondition(DiskScanner.skipsStartupEntry(parent: parent, name: name))
        }
        for name in ["Users", "Applications", "Library", "System", "opt", "private", "usr"] {
            precondition(!DiskScanner.skipsStartupEntry(parent: "/", name: name))
        }
        precondition(!DiskScanner.skipsStartupEntry(parent: "/Users/test", name: "Volumes"))
        let log = InventoryLog()
        let result = try await DiskScanner.scan(folder, wholeDisk: true, onInventory: { log.updates.append($0) })
        precondition(log.updates.first?.pendingDirectories == 2)
        precondition(log.updates.contains { $0.pendingDirectories == 2 && $0.entries.allSatisfy { $0.bytes > 100_000 } })
        precondition(!result.isPartial && Set(result.entries.map(\.name)) == Set(names))
        var expected: Int64 = 0
        var inodes = Set<ino_t>()
        for branch in result.entries {
            for url in [branch.url] + (try fm.contentsOfDirectory(at: branch.url, includingPropertiesForKeys: nil)) {
                var s = stat()
                precondition(lstat(url.path, &s) == 0)
                if inodes.insert(s.st_ino).inserted { expected += s.st_blocks * 512 }
            }
        }
        precondition(result.totalBytes == expected && result.children.count == 2)
        model.scan(folder)
        model.startIfNeeded()
        precondition(model.location?.path == folder.path && !model.wholeDisk)
        for _ in 0..<500 where model.running { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.running)
        model.enter(model.result!.entries[0].url)
        precondition(model.history == [folder.standardizedFileURL] && model.result?.entries.count ?? 0 >= 680)
        model.back()
        precondition(model.location == folder.standardizedFileURL && model.result?.totalBytes == expected)
        print("Passed startup root, mount exclusions, fair live sizing, hard-link accounting, folder override, cached drill and return.")
    }
}
