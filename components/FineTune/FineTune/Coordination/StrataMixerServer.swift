import Darwin
import Foundation

final class StrataMixerServer {
    private let source: DispatchSourceRead

    init?(handle: @escaping @Sendable (Data, pid_t, TimeInterval) -> Data?) {
        let dir = FineTuneSocket.directory
        guard mkdir(dir, 0o700) == 0 || errno == EEXIST else { return nil }
        var info = stat()
        guard lstat(dir, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { return nil }
        let pid = getpid()
        let path = FineTuneSocket.path(for: pid)
        // Normal shutdown removes our socket. Reclaim sockets left by killed
        // processes after checking ownership, file type, and PID liveness.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for file in files where file.hasPrefix("v2-") {
            guard let previous = pid_t(file.dropFirst(3)), previous > 0,
                  previous == pid || (kill(previous, 0) < 0 && errno == ESRCH) else { continue }
            let old = FineTuneSocket.path(for: previous)
            if lstat(old, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK { unlink(old) }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard FineTuneSocket.configure(fd),
              FineTuneSocket.withAddress(for: pid, { Darwin.bind(fd, $0, $1) }) == 0 else {
            close(fd)
            return nil
        }
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            return nil
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "FineTune.StrataMixerServer"))
        self.source = source
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            let deadline = FineTuneSocket.deadline()
            guard FineTuneSocket.configure(client), let peer = FineTuneSocket.peerPID(client),
                  let request = FineTuneSocket.read(client, limit: FineTuneSocket.requestLimit, until: deadline) else { return }
            let response = handle(request, peer, deadline) ?? Data()
            guard response.count <= FineTuneSocket.responseLimit else { return }
            _ = FineTuneSocket.write(response, to: client, until: deadline)
        }
        source.setCancelHandler { close(fd); unlink(path) }
        source.resume()
    }

    deinit { source.cancel() }
}
