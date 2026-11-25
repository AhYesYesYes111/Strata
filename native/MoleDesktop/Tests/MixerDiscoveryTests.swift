import AppKit

@main
enum MixerDiscoveryTests {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        // Keep the fixture's socket path within sockaddr_un.sun_path.
        let temp = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let directory = temp.appendingPathComponent("ft-mixer")
        var changes: [Bool] = []
        guard let watcher = MixerSocketDirectory(path: directory.path, changed: { changes.append($0) }) else {
            fatalError("Could not watch fixture directory")
        }
        try await wait { !changes.isEmpty }
        changes.removeAll()
        let entry = directory.appendingPathComponent("v2-\(getpid())")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        let bytes = Array(entry.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        precondition(bound == 0)
        try await wait { changes.contains(false) }
        let identifiers = [NSRunningApplication.current.bundleIdentifier].compactMap { $0 }
        precondition(watcher.hasPendingPeer(identifiers: identifiers))
        try fm.removeItem(at: entry)
        precondition(!watcher.hasPendingPeer(identifiers: identifiers))
        try fm.moveItem(at: directory, to: temp.appendingPathComponent("old"))
        try await wait { changes.contains(true) }
        withExtendedLifetime(watcher) {}

        // When a path cannot host a bridge socket, discovery must be able to poll.
        try Data().write(to: directory)
        precondition(MixerSocketDirectory(path: directory.path) { _ in } == nil)
        print("PASS mixer discovery, directory replacement and polling fallback")
    }

    @MainActor
    private static func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            precondition(ContinuousClock.now < deadline, "Missing directory event")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
