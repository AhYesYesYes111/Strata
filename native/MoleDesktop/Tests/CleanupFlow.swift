import Darwin
import Foundation

private struct TestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure(message: message) }
}

@main
struct CleanupFlow {
    @MainActor private static func wait(until condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw TestFailure(message: "Timed out waiting for the fixture")
    }

    private static func verifyReport(in home: URL) throws {
        let report = CleanupReport(
            summaryText: ReportText("共 2 项", "2 items"), groups: [
                PreviewGroup(title: "App caches", entries: [
                    PreviewEntry(id: 0, path: "/示例/Cache.bin", detail: "8MB"),
                    PreviewEntry(id: 1, path: "/示例/旧文件", detail: "size unknown")
                ])
            ], transcript: "开始\nRead CaChe\n完成", notice: ReportText("部分测量", "Partial result")
        )
        let originalPaths = report.groups.flatMap(\.entries).map(\.path)
        func paths(_ search: String) -> [String] { report.matchingGroups(search).flatMap(\.entries).map(\.path) }
        try require(paths("  ") == originalPaths, "Empty search lost paths")
        try require(paths("应用缓存") == originalPaths && paths("App caches") == originalPaths, "Group search lost entries")
        try require(paths("cache.bin") == [originalPaths[0]] && paths(" UNKNOWN ") == [originalPaths[1]], "Path/detail search mismatch")
        try require(paths("nothing").isEmpty && report.matchingLogLines("nobody").isEmpty, "Unmatched query returned results")
        try require(report.matchingLogLines("cache").map(String.init) == ["Read CaChe"], "Transcript search mismatch")
        let file = home.appendingPathComponent("导出.txt")
        try report.writeReport(titled: "清理报告", to: file)
        let output = try String(contentsOf: file, encoding: .utf8)
        for text in originalPaths + ["清理报告", report.summary, "大小未知", "部分测量", report.transcript] {
            try require(output.contains(text), "Full export omitted " + text)
        }
    }

    @MainActor static func main() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expected = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try require(home.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath(), "Fixture HOME mismatch")
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.key)
        try verifyReport(in: expected)
        let mode = expected.appendingPathComponent("mode")
        let calls = expected.appendingPathComponent("calls")
        func history() throws -> [String] {
            try String(contentsOf: calls, encoding: .utf8).components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        func setMode(_ value: String) throws {
            try (value + "\n").write(to: mode, atomically: true, encoding: .utf8)
        }

        let clean = PreviewModel(kind: .clean)
        let maintenance = PreviewModel(kind: .optimize)
        let timingKey = "strata.timing.v1.clean"
        let initialClean = UserDefaults.standard.data(forKey: timingKey)
        clean.applyAfterConfirmation()
        try require(!clean.running && (try history()).isEmpty, "Apply without a preview launched the CLI")

        for invalid in ["missing", "mismatch", "stale"] {
            try setMode(invalid)
            clean.start()
            try await wait { !clean.running }
            try require(clean.report?.canApplyClean == false && clean.report?.detailNotice != nil,
                        "Unverified ledger passed approval in \(invalid) mode")
            clean.applyAfterConfirmation()
            try require(!clean.running, "Model accepted an unverified preview")
        }

        try setMode("partial")
        maintenance.start()
        try await wait { !maintenance.running }
        try require(maintenance.report?.summary.contains("3") == true, "Unexpected optimize preview")
        try require(maintenance.report?.summary.contains("部分检查失败") == true, "Incomplete maintenance reported success")
        maintenance.applyAfterConfirmation()
        try require(!maintenance.running, "Optimize preview unlocked a mutation")

        try setMode("valid")
        clean.start()
        try await wait { !clean.running }
        try require(clean.report?.groups.first?.entries.first?.path == home.appendingPathComponent("example.fixture").path,
                    "Verified path missing from preview")
        try require(clean.report?.canApplyClean == true, "Valid preview failed verification")
        try require(clean.scanEstimate.basis == "参考上次扫描", "Completed preview did not calibrate scan timing")
        try require(UserDefaults.standard.data(forKey: timingKey) == initialClean, "Preview recorded a real clean duration")
        guard let captured = clean.report else { throw TestFailure(message: "Missing preview") }
        let raw = captured.transcript
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.key)
        try require(clean.report?.summary == "8MB reclaimable · 1 item", "Finished preview retained its original language")
        try require(maintenance.report?.summary == "Some checks failed · 3 available maintenance tasks",
                    "Finished maintenance warning retained its original language")
        try require(clean.scanEstimate.basis == "Last scan" && clean.report?.transcript == raw,
                    "Switch lost timing history or modified CLI output")
        let export = expected.appendingPathComponent("English-report.txt")
        try captured.writeReport(titled: "Cleanup preview", to: export)
        let englishExport = try String(contentsOf: export, encoding: .utf8)
        try require(englishExport.contains("User caches (1 path)") && englishExport.contains("Run log") &&
                    englishExport.contains(raw), "English export lost labels or changed its transcript")
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.key)
        let previewCalls = ["clean preview", "clean preview", "clean preview", "optimize preview", "clean preview"]
        try require(try history() == previewCalls, "Preview initiated a mutation or ran the wrong CLI arguments")

        try setMode("changed")
        clean.applyAfterConfirmation()
        try await wait { !clean.running }
        try require(!clean.didClean && clean.report?.canApplyClean == true && clean.message != nil,
                    "Changed candidate list failed to require fresh confirmation")
        try require(clean.report?.groups.first?.entries.first?.path == home.appendingPathComponent("updated.fixture").path,
                    "Reconfirmation kept the obsolete candidate list")
        try require(try history() == previewCalls + ["clean preview"], "Changed candidates reached cleanup")

        try setMode("owner")
        clean.applyAfterConfirmation()
        try await wait { !clean.running }
        try require(!clean.didClean && clean.report?.canApplyClean == true, "Changed Homebrew details reused approval")
        try require(clean.report?.transcript.contains("libfixture 3.0") == true, "Updated Homebrew detail missing")

        clean.applyAfterConfirmation()
        try await wait { !clean.running }
        try require(clean.didClean && clean.report?.transcript.contains("Removed: 8MB · 1 item") == true,
                    "Confirmed run omitted its execution transcript")
        try require(clean.report?.canApplyClean == false, "Execution report permits a second mutation")
        let completedClean = UserDefaults.standard.data(forKey: timingKey)
        try require(completedClean != nil && completedClean != initialClean && clean.cleanEstimate.basis == "参考上次清理",
                    "Successful execution did not record its own duration")
        clean.applyAfterConfirmation()
        try require(!clean.running && (try history()) == previewCalls + ["clean preview", "clean preview", "clean preview", "clean apply"], "Duplicate apply")

        try setMode("slow")
        clean.start()
        try await wait { !clean.running }
        clean.applyAfterConfirmation()
        let waiting = expected.appendingPathComponent("waiting-pid")
        try await wait { FileManager.default.fileExists(atPath: waiting.path) }
        guard let pid = Int32(try String(contentsOf: waiting).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TestFailure(message: "Missing recorder PID")
        }
        try require(clean.running && clean.applying, "Cancellation fixture did not reach apply")
        clean.cancel()
        try await wait { !clean.running }
        try require(!clean.didClean && clean.report == nil && clean.message?.contains("已完成的更改会保留") == true,
                    "Stopped clean did not disclose incomplete work")
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.key)
        try require(clean.message?.contains("Completed changes are permanent") == true,
                    "Finished cancellation warning retained its original language")
        try require(UserDefaults.standard.data(forKey: timingKey) == completedClean,
                    "Cancelled execution replaced the last successful clean timing")
        try require(kill(pid, 0) == -1 && errno == ESRCH, "Cancelled child remains alive")
        try require(try history() == previewCalls + ["clean preview", "clean preview", "clean preview", "clean apply", "clean preview", "clean preview", "clean apply"], "Unexpected command sequence")
        print("Passed cleanup flow: gated confirmation, CLI arguments and environment, ledger checks, transcript, cancellation")
    }
}
