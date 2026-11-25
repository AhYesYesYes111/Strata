// Wire format shared with Strata: one UTF-8 JSON request per local connection.
// Each writer half-closes its stream. An empty reply acknowledges a command.
import Darwin
import Foundation

enum FineTuneSocket {
    static let directory: String = {
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard count > 1 else { return "" }
        var bytes = [CChar](repeating: 0, count: count)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &bytes, count) == count else { return "" }
        return URL(fileURLWithPath: String(cString: bytes)).appendingPathComponent("ft-mixer").path
    }()
    static let requestLimit = 16 * 1024
    static let responseLimit = 256 * 1024

    static func path(for pid: pid_t) -> String { "\(directory)/v2-\(pid)" }
    static func deadline() -> TimeInterval { ProcessInfo.processInfo.systemUptime + 1 }

    static func withAddress(for pid: pid_t, _ operation: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        guard !directory.isEmpty else { return -1 }
        var address = sockaddr_un()
        let path = Array(path(for: pid).utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { operation($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func configure(_ fd: Int32) -> Bool {
        var yes: Int32 = 1
        return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0
    }

    static func peerPID(_ fd: Int32) -> pid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout.size(ofValue: pid))
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    static func ready(_ fd: Int32, for event: Int16, until deadline: TimeInterval) -> Bool {
        var pfd = pollfd(fd: fd, events: event, revents: 0)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            let result = poll(&pfd, 1, Int32(ceil(remaining * 1_000)))
            if result < 0 && errno == EINTR { continue }
            return result > 0 && (pfd.revents & (event | Int16(POLLHUP))) != 0
        }
    }

    static func read(_ fd: Int32, limit: Int, until deadline: TimeInterval) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ready(fd, for: Int16(POLLIN), until: deadline) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0, count <= limit - data.count else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }

    static func write(_ data: Data, to fd: Int32, until deadline: TimeInterval) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard ready(fd, for: Int16(POLLOUT), until: deadline), let base = bytes.baseAddress else { return false }
                let sent = Darwin.write(fd, base + offset, bytes.count - offset)
                if sent < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard sent > 0 else { return false }
                offset += sent
            }
            return shutdown(fd, SHUT_WR) == 0
        }
    }
}
