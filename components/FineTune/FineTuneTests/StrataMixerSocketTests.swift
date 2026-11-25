import Darwin
import Foundation
import Testing
@testable import FineTune

@Suite("Strata mixer stream framing")
struct StrataMixerSocketTests {
    @Test(arguments: [0, 1, 4096, 4097, 16_384, 16_385])
    func requestBoundary(count: Int) async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { sockets.forEach { close($0) } }
        try #require(sockets.allSatisfy(FineTuneSocket.configure))
        let deadline = FineTuneSocket.deadline()
        let payload = Data(repeating: 65, count: count)
        let reader = sockets[1]
        async let response = Task.detached {
            FineTuneSocket.read(reader, limit: FineTuneSocket.requestLimit, until: deadline)
        }.value
        let written = FineTuneSocket.write(payload, to: sockets[0], until: deadline)
        let received = await response
        try #require(written)
        #expect(received == (count > FineTuneSocket.requestLimit ? nil : payload))
    }
}
