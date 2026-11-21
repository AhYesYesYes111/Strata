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
        try await testPrivacy(in: folder)
        print("Passed startup root, fair sizing, hard links, navigation, privacy boundaries and explicit folder selection.")
    }

    @MainActor static func testPrivacy(in folder: URL) async throws {
        let fm = FileManager.default
        let home = folder.appendingPathComponent("test-home", isDirectory: true)
        let privacy = DiskScanPrivacy(home: home)
        let bytes = Data(repeating: 0x54, count: 65_536)
        let protected = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", ".Trash",
                         "Library/Group Containers", "Library/Containers", "Library/CloudStorage",
                         "Library/Mobile Documents", "Library/Application Support/AddressBook",
                         "Projects/Relocated.PhotosLibrary"]
        let ordinary = "Projects/Desktop"
        for name in protected + [ordinary] {
            let dir = home.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes.write(to: dir.appendingPathComponent("payload"))
        }
        let scoped = try await DiskScanner.scan(home, privacy: privacy)
        let homeBoundaries = scoped.entries.filter(\.requiresSelection)
        precondition(scoped.isPartial && homeBoundaries.count == 7)
        precondition(homeBoundaries.allSatisfy { $0.bytes == 0 && $0.isPartial })
        let lib = scoped.entries.first { $0.name == "Library" }!
        let projects = scoped.entries.first { $0.name == "Projects" }!
        precondition(lib.isPartial && lib.bytes < Int64(bytes.count))
        precondition(projects.isPartial && projects.bytes >= Int64(bytes.count) && projects.bytes < Int64(bytes.count * 2))
        let startingAboveHome = try await DiskScanner.scan(folder, wholeDisk: true, privacy: privacy)
        let account = startingAboveHome.entries.first { $0.name == home.lastPathComponent }!
        precondition(account.isPartial && account.bytes >= projects.bytes && account.bytes < Int64(bytes.count * 2))
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        for selection in [nil, home] {
            do {
                _ = try await DiskScanner.scan(downloads, selectedFolder: selection, privacy: privacy)
                preconditionFailure("Recursive or enclosing selection must not open a protected folder")
            } catch DiskScanAccessError.selectFolder {}
        }
        let album = downloads.appendingPathComponent("Travel.photoslibrary", isDirectory: true)
        try fm.createDirectory(at: album, withIntermediateDirectories: true)
        try bytes.write(to: album.appendingPathComponent("private-item"))
        let selected = try await DiskScanner.scan(downloads, selectedFolder: downloads, privacy: privacy)
        precondition(selected.entries.contains { $0.name == "payload" && $0.bytes > 0 })
        precondition(selected.entries.contains { $0.url == album && $0.requiresSelection && $0.bytes == 0 })
        let nested = downloads.appendingPathComponent("Work", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        precondition(!privacy.needsSelection(nested, selectedFolder: downloads))
        precondition(privacy.needsSelection(album, selectedFolder: downloads))
        let albumContents = try await DiskScanner.scan(album, selectedFolder: album, privacy: privacy)
        precondition(!albumContents.isPartial && albumContents.entries.map(\.name) == ["private-item"])
        let model = DiskModel()
        model.scan(album)
        try await finish(model)
        precondition(model.needsFolderSelection && model.result == nil)
        model.scan(album, userSelected: true)
        try await finish(model)
        precondition(model.result?.entries.map(\.name) == ["private-item"])
        model.refresh()
        try await finish(model)
        precondition(model.result?.entries.map(\.name) == ["private-item"])
        model.scan(album)
        try await finish(model)
        precondition(model.needsFolderSelection, "A new automatic scan must not inherit the prior selection")
        for path in ["/var/root/Desktop", "/private/var/root/Documents", "/Users/another-user/Desktop", "/Users/sibling/../another-user/Desktop/Sub",
                     "/Users/Shared/Photos.photoslibrary", "/System/Volumes/Data/Users/someone/Library/Containers",
                     "/System/Volumes/Data/Users/someone/Documents/Projects"] {
            precondition(privacy.needsSelection(URL(fileURLWithPath: path, isDirectory: true), selectedFolder: nil))
        }
        precondition(!privacy.needsSelection(URL(fileURLWithPath: "/Users/Shared/Desktop", isDirectory: true), selectedFolder: nil))
        // A previously accessible parent can be replaced by a link between drill-downs.
        let alias = home.appendingPathComponent("replaced", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: downloads)
        do {
            _ = try await DiskScanner.scan(alias.appendingPathComponent("Work", isDirectory: true), privacy: privacy)
            preconditionFailure("An intermediate link must not lead a direct scan into Downloads")
        } catch let err as NSError {
            precondition(err.domain == NSPOSIXErrorDomain && err.code == Int(ELOOP))
        }
    }

    @MainActor static func finish(_ model: DiskModel) async throws {
        for _ in 0..<500 where model.running { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.running)
    }
}
