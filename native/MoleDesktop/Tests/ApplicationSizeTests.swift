import Foundation

@MainActor private final class Measurements {
    var calls: [URL: Int] = [:]
    var pending: [URL: CheckedContinuation<Int64?, Never>] = [:]

    func measure(_ url: URL) async -> Int64? {
        calls[url, default: 0] += 1
        return await withCheckedContinuation { pending[url] = $0 }
    }

    func finish(_ url: URL, bytes: Int64?) {
        pending.removeValue(forKey: url)!.resume(returning: bytes)
    }
}

@main struct ApplicationSizeTests {
    @MainActor static func main() async throws {
        let work = Measurements()
        let urls = (0..<5).map { URL(fileURLWithPath: "/test/\($0).app", isDirectory: true) }
        let sizes = ApplicationSizes { await work.measure($0) }

        for url in urls { sizes.request(url) }
        await until { work.calls.count == 3 }
        precondition(Set(work.calls.keys) == Set(urls.prefix(3)))

        sizes.hide(urls[0])
        sizes.request(urls[0])
        sizes.hide(urls[3])
        work.finish(urls[0], bytes: 123)
        await until { work.pending[urls[4]] != nil }
        precondition(work.calls[urls[0]] == 1 && work.calls[urls[3]] == nil)
        sizes.request(urls[0])
        precondition(sizes.measured[urls[0]] == .measured(123))
        work.finish(urls[1], bytes: nil)
        await until { sizes.measured[urls[1]] == .unavailable }

        sizes.request(urls[3])
        await until { work.pending[urls[3]] != nil }
        sizes.close()
        for url in urls.dropFirst(2) { work.finish(url, bytes: 234) }
        let refreshed = ApplicationSizes { await work.measure($0) }
        refreshed.request(urls[0])
        await until { work.pending[urls[0]] != nil }
        work.finish(urls[0], bytes: 456)
        await until { refreshed.measured[urls[0]] == .measured(456) }
        precondition(work.calls[urls[0]] == 2 && sizes.measured.count == 2)
        print("Passed on-demand size concurrency, scrolling, cache, cancellation and refresh checks.")
    }

    @MainActor private static func until(_ ready: () -> Bool) async {
        for _ in 0..<200 where !ready() { try? await Task.sleep(nanoseconds: 5_000_000) }
        precondition(ready())
    }
}
