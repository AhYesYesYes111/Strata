import Foundation

@main
struct MenuActivityTests {
    static func main() throws {
        let timestamp = "2026-11-20 21:24:00"
        func end(_ command: String, _ count: Int, _ size: String) -> String {
            "# ========== \(command) session ended at \(timestamp), \(count) items, \(size) ==========\n"
        }
        func change(_ command: String, _ action: String) -> String {
            "[\(timestamp)] [\(command)] \(action) /fixture/path\n"
        }

        var log = change("clean run=actual", "REMOVED") + change("uninstall run=apps", "TRASHED")
        log += change("optimize run=maintenance", "REBUILT") + end("uninstall run=apps", 3, "80MB")
        log += end("clean run=actual", 11, "1.24GB") + end("optimize run=maintenance", 4, "0B")
        log += change("clean-dry-run run=preview", "REMOVED") + end("clean-dry-run run=preview", 200, "12GB")
        log += change("clean run=skipped", "SKIPPED") + end("clean run=skipped", 6, "3GB")
        log += change("clean run=interrupted", "REMOVED") + end("clean run=unrelated", 1, "1GB")
        log += end("clean run=actual", 11, "1.24GB")
        let expected = MenuActivityTotals(cleaned: 1_240_000_000, uninstalled: 3, optimized: 4)
        precondition(MenuActivityTotals.parse(Data(log.utf8)) == expected)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        precondition(MenuActivityTotals.read(from: url) == nil)
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(repeating: 65, count: 1_048_600)
        data.append(10)
        data.append(contentsOf: log.utf8)
        data.append(contentsOf: change("clean run=partial", "REMOVED").utf8)
        data.append(contentsOf: end("clean run=partial", 1, "1GB").dropLast().utf8)
        try data.write(to: url)
        precondition(MenuActivityTotals.read(from: url) == expected)
        print("Passed recorded session totals, interleaved runs, preview exclusion and bounded log reads.")
    }
}
