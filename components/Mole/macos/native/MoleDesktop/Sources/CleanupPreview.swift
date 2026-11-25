import AppKit
import Darwin
import Foundation

enum PreviewKind: String {
    case clean, optimize
}

struct PreviewEntry: Identifiable {
    let id: Int
    let path: String
    let detail: String

    var displayDetail: String {
        guard AppLanguage.current.resolved == .chinese else { return detail }
        // A covering path may contain any of the same words as a ledger label.
        let delimiter = detail.range(of: ", counted under ")
        let prefix = delimiter.map { String(detail[..<$0.lowerBound]) } ?? detail
        let fields = prefix.components(separatedBy: ", ").map { field in
            if field == "size unknown" { return "大小未知" }
            if field.hasSuffix(" items"), let count = Int(field.dropLast(6)) { return String(count) + " 项" }
            return field
        }
        let path = delimiter.map { "，已计入 " + detail[$0.upperBound...] } ?? ""
        return fields.joined(separator: "，") + path
    }
}

struct PreviewGroup: Identifiable {
    var id: String { title }
    let title: String
    var entries: [PreviewEntry]
}

// A finished report or failure can outlive the language it was captured in.
struct ReportText: LocalizedError {
    let chinese: String
    let english: String
    var value: String { tr(chinese, english) }
    var errorDescription: String? { value }

    init(_ chinese: String, _ english: String) {
        self.chinese = chinese
        self.english = english
    }

    init(_ error: Error) {
        if let text = error as? ReportText { self = text }
        else { self.init(error.localizedDescription, error.localizedDescription) }
    }
}

struct CleanupPlan: Equatable {
    let ledgerDigest: String
    let operationRows: [String]
}

struct CleanupReport {
    let summaryText: ReportText
    var summary: String { summaryText.value }
    let groups: [PreviewGroup]
    let transcript: String
    let notice: ReportText?
    var detailNotice: String? { notice?.value }
    var previewSize: String?
    var previewItemCount: Int?
    var plan: CleanupPlan?
    var canApplyClean: Bool { plan != nil && !logClipped }
    var logClipped = false
    var completedClean = false
}

enum CleanupPreview {
    private enum Request {
        case preview(PreviewKind), confirmedClean
    }

    // Only one bundled CLI may be scanning or mutating from this app. Keep
    // ownership through async cancellation and subprocess termination.
    private actor Runner {
        var busy = false

        func perform(_ request: Request, approved: CleanupPlan? = nil, onProgress: @escaping @Sendable (String) -> Void) async throws -> CleanupReport {
            guard !busy else { throw ReportText("另一个 Mole 任务正在运行。请等该任务结束。", "Another Mole task is running. Wait for it to finish.") }
            busy = true
            defer { busy = false }
            if case .confirmedClean = request {
                let fresh = try await execute(.preview(.clean), onProgress: onProgress)
                guard fresh.canApplyClean, let approved, fresh.plan == approved else {
                    return fresh
                }
            }
            return try await execute(request, onProgress: onProgress)
        }
    }

    private static let runner = Runner()

    static func run(_ kind: PreviewKind,
                    onProgress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CleanupReport {
        try await runner.perform(.preview(kind), onProgress: onProgress)
    }

    /// The caller consumes a successful preview and obtains explicit consent
    /// for a fresh full clean. Never turn report text into deletion inputs.
    static func applyConfirmedClean(_ plan: CleanupPlan, onProgress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CleanupReport {
        try await runner.perform(.confirmedClean, approved: plan, onProgress: onProgress)
    }

    private static func execute(_ request: Request,
                                onProgress: @escaping @Sendable (String) -> Void) async throws -> CleanupReport {
        try Task.checkCancellation()
        guard let launcher = Bundle.main.resourceURL?.appendingPathComponent("mole-cli/mole"),
              FileManager.default.isExecutableFile(atPath: launcher.path) else {
            throw ReportText("找不到随应用提供的 Mole CLI。请重新构建应用。", "The bundled Mole CLI is missing. Rebuild or reinstall Strata.")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let process = Process()
        process.executableURL = launcher
        process.currentDirectoryURL = home
        // A GUI launch has no login shell. Pass only the environment needed by
        // the bundled CLI, never inherited shell hooks or test path overrides.
        var environment = [
            "HOME": home.path, "USER": NSUserName(), "LOGNAME": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "TERM": "dumb", "LC_ALL": "C", "NO_COLOR": "1", "_MOLE_STRATA_GUI": "1"
        ]
        let action: ReportText
        let incomplete: ReportText
        switch request {
        case .preview(let kind):
            process.arguments = [kind.rawValue, "--dry-run"]
            environment["MOLE_DRY_RUN"] = "1"
            if kind == .optimize { environment["MOLE_TEST_NO_AUTH"] = "1" }
            action = ReportText("预览", "preview")
            incomplete = ReportText("", "")
        case .confirmedClean:
            process.arguments = ["clean"]
            action = ReportText("清理", "cleanup")
            incomplete = ReportText("已完成的更改会保留。请查看 Mole 操作记录并重新扫描。",
                                    " Completed changes are permanent. Review the Mole operation log and scan again.")
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ReportText("无法读取 CLI 输出。请重新扫描。", "Could not read CLI output. Run the scan again.")
        }

        let started = Date()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(600))
        var output = Data()
        var pendingLine: [UInt8] = []
        var lastHeading: String?
        var clipped = false
        try process.run()
        let termination = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in signalProcess(process, SIGTERM) }
        defer {
            NotificationCenter.default.removeObserver(termination)
            try? pipe.fileHandleForReading.close()
        }
        do {
            // Pipes are drained while the process runs. Keep the tail (which
            // contains the CLI's authoritative, deduplicated summary).
            var buffer = [UInt8](repeating: 0, count: 32_768)
            while true {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw ReportText("\(action.chinese)超过十分钟，已停止。",
                                     "The \(action.english) stopped after ten minutes.")
                }
                let running = process.isRunning
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    let chunk = buffer.prefix(count)
                    output.append(contentsOf: chunk)
                    if let heading = latestHeading(in: chunk, pendingLine: &pendingLine), heading != lastHeading {
                        lastHeading = heading
                        onProgress(heading)
                    }
                    if output.count > 512 * 1024 {
                        output.removeFirst(output.count - 384 * 1024)
                        clipped = true
                    }
                    continue
                }
                if count < 0 && errno != EAGAIN && errno != EINTR {
                    throw ReportText("无法读取 CLI 输出。", "Could not read CLI output.")
                }
                if !running && (count == 0 || errno != EINTR) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            await stop(process)
            if case .confirmedClean = request {
                let cause = error is CancellationError ? ReportText("清理已停止。", "Cleanup stopped.") : ReportText(error)
                throw ReportText(cause.chinese + incomplete.chinese, cause.english + incomplete.english)
            }
            throw error
        }

        let transcript = readableTranscript(output)
        // Optimize can finish its complete report with exit 1 when a single
        // check fails. Keep the failing check and the other findings visible.
        if case .preview(.optimize) = request,
           process.terminationReason == .exit, process.terminationStatus == 1,
           !summaryLines(transcript, heading: "Dry Run Complete, No Changes Made").isEmpty {
            let partial = report(.optimize, transcript: transcript, home: home, started: started)
            return CleanupReport(summaryText: ReportText("部分检查失败 · " + partial.summaryText.chinese,
                                                         "Some checks failed · " + partial.summaryText.english),
                                 groups: [], transcript: transcript,
                                 notice: ReportText("运行记录中列出了失败或跳过的维护项目。",
                                                    "The run log lists failed or skipped checks."), logClipped: clipped)
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let lines = transcript.split(separator: "\n").filter { $0.contains(where: { $0 != "=" }) }
            let reason = lines.suffix(3).joined(separator: "\n")
            throw ReportText("CLI \(action.chinese)未完成（退出码 \(process.terminationStatus)）。\(incomplete.chinese)\n\(reason)",
                             "CLI \(action.english) exited with code \(process.terminationStatus).\(incomplete.english)\n\(reason)")
        }
        switch request {
        case .preview(let kind):
            try Task.checkCancellation()
            var result = report(kind, transcript: transcript, home: home, started: started)
            result.logClipped = clipped
            return result
        case .confirmedClean:
            let lines = summaryLines(transcript, heading: "Cleanup complete")
            let removed = lines.first(where: { $0.hasPrefix("Removed: ") })
            let summary = removed.map { line in
                let fields = line.dropFirst("Removed: ".count).components(separatedBy: " · ")
                let count = fields.dropFirst().first?.split(separator: " ").first.flatMap { Int($0) }
                let amount = fields[0] == "Partially measured" ? "大小仅部分可测" : fields[0]
                let chinese = "已清理 " + amount + (count.map { " · " + String($0) + " 项" } ?? "")
                return ReportText(chinese, String(line))
            } ?? ReportText("CLI 已完成清理", "Cleanup complete")
            return CleanupReport(summaryText: summary, groups: [], transcript: transcript, notice: nil, logClipped: clipped, completedClean: true)
        }
    }

    // Both commands print "➤ <section>" on a separate plain-text line.
    // Buffer short lines by byte so a pipe read may split the UTF-8 arrow.
    private static func latestHeading(in chunk: ArraySlice<UInt8>, pendingLine: inout [UInt8]) -> String? {
        var latest: String?
        for byte in chunk {
            if byte == 0x0a {
                if pendingLine.count <= 200, pendingLine.starts(with: "➤ ".utf8),
                   let heading = String(bytes: pendingLine.dropFirst("➤ ".utf8.count), encoding: .utf8),
                   !heading.isEmpty, heading.rangeOfCharacter(from: .controlCharacters) == nil {
                    latest = heading
                }
                pendingLine.removeAll(keepingCapacity: true)
            } else if pendingLine.count <= 200 {
                pendingLine.append(byte)
            }
        }
        return latest
    }

    private static func signalProcess(_ process: Process, _ number: Int32) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        // Foundation normally gives the CLI its own process group on macOS.
        // Signal workers together only after confirming this is that group.
        let target = getpgid(pid) == pid ? -pid : pid
        _ = Darwin.kill(target, number)
    }

    private static func stop(_ process: Process) async {
        signalProcess(process, SIGTERM)
        // Finish cancellation before the UI can start another preview writing
        // the same CLI ledger. The caller's task is already cancelled.
        await Task.detached {
            for _ in 0..<20 {
                guard process.isRunning else { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            signalProcess(process, SIGKILL)
            process.waitUntilExit()
        }.value
    }

    private static func readableTranscript(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Only the final delimited summary block may enable the real command.
    // Earlier output can include arbitrary filenames or third-party messages.
    private static func summaryLines(_ transcript: String, heading: String) -> [Substring] {
        let lines = transcript.split(separator: "\n")
        guard let end = lines.lastIndex(where: { $0.count >= 3 && $0.allSatisfy { $0 == "=" } }),
              let start = lines[..<end].lastIndex(where: { $0.count >= 3 && $0.allSatisfy { $0 == "=" } }),
              lines[start + 1] == Substring(heading) else { return [] }
        return Array(lines[(start + 2)..<end])
    }

    // Some owner commands (including Homebrew) describe their plans in the
    // section output. Keep each indented detail bound to its action, and
    // ignore traversal order, progress messages and host free-space readings.
    private static func operationRows(_ lines: [Substring]) -> [String] {
        var rows: [String] = []
        var section = ""
        var action: String?
        for line in lines {
            if line.hasPrefix("    "), let action {
                rows.append(action + "\n" + line)
            } else {
                action = nil
                if line.hasPrefix("➤ ") { section = String(line) }
                if line.hasPrefix("  ○ ") {
                    let row = section + "\n" + line
                    rows.append(row)
                    action = row
                }
            }
        }
        return rows.sorted()
    }

    static func report(_ kind: PreviewKind, transcript: String, home: URL, started: Date) -> CleanupReport {
        let lines = transcript.split(separator: "\n")
        switch kind {
        case .optimize:
            let applied = lines.last(where: { $0.hasPrefix("Would apply ") })?
                .split(separator: " ").dropFirst(2).first.flatMap { Int($0) }
            let summary = applied.map { ReportText("预计可执行 \($0) 项维护",
                                                   $0 == 1 ? "1 available maintenance task" : "\($0) available maintenance tasks") }
                ?? ReportText("维护预览完成", "Maintenance preview complete")
            return CleanupReport(summaryText: summary, groups: [], transcript: transcript, notice: nil)
        case .clean:
            guard let stats = lines.last(where: { $0.hasPrefix("Potential space: ") }) else {
                let empty = lines.contains { $0.hasPrefix("No significant reclaimable space detected") ||
                    $0.hasPrefix("No additional reclaimable space detected") }
                return CleanupReport(summaryText: empty ? ReportText("本次扫描未发现可回收空间", "No reclaimable space found")
                                                       : ReportText("清理预览完成", "Cleanup preview complete"),
                                     groups: [], transcript: transcript,
                                     notice: empty ? nil : ReportText("CLI 未返回可识别的空间估算。",
                                                                      "The CLI did not return a usable size estimate."))
            }
            let fields = stats.dropFirst("Potential space: ".count).components(separatedBy: " · ")
            let size = fields[0]
            let items = fields.dropFirst().first?.split(separator: " ").first.flatMap { Int($0) }
            let summary = ReportText("预计可回收 \(size)" + (items.map { " · \($0) 项" } ?? ""),
                                     "\(size) reclaimable" + (items.map { $0 == 1 ? " · 1 item" : " · \($0) items" } ?? ""))
            let url = home.appendingPathComponent(".config/mole/clean-list.txt")
            let missing = ReportText("此轮预览没有可核对的路径明细。请查看 CLI 输出。",
                                     "No verified path list is available for this scan. See the run log.")
            guard lines.contains("Detailed file list: \(url.path)"),
                  let ledger = recentLedger(url, started: started),
                  ledger.hasPrefix("# Mole Cleanup Preview - ") else {
                return CleanupReport(summaryText: summary, groups: [], transcript: transcript, notice: missing)
            }
            let rows = ledger.split(separator: "\n")
            let footer = rows.suffix(5)
            guard footer.contains("# Potential cleanup: \(size)"),
                  items.map({ footer.contains("# Items: \($0)") }) ?? true else {
                return CleanupReport(summaryText: summary, groups: [], transcript: transcript, notice: missing)
            }
            let (groups, truncated) = parseEntries(rows)
            let notice = truncated ? ReportText("界面显示前 1,000 条路径。完整清单见 CLI 输出中的文件。",
                                                "Showing the first 1,000 paths. The run log identifies the full list.") : nil
            let final = summaryLines(transcript, heading: "Dry run complete - no changes made")
            let recognizedSize = size.range(of: #"^[0-9]+(\.[0-9]+)?(B|KB|MB|GB|TB)\+?$"#,
                                            options: .regularExpression) != nil
            let positiveBytes = (Double(size.prefix(while: { $0.isNumber || $0 == "." })) ?? 0) > 0
            let digest = final.first { $0.hasPrefix("Candidate digest: ") }
                .map { String($0.dropFirst("Candidate digest: ".count)) }
            let verifiedDigest = digest.flatMap { value in
                value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil &&
                    footer.contains("# Candidate digest: \(value)") ? value : nil
            }
            let verified = recognizedSize && positiveBytes && (items ?? 0) > 0 && !groups.isEmpty &&
                final.contains(stats) && final.contains("Detailed file list: \(url.path)")
            return CleanupReport(summaryText: summary, groups: groups, transcript: transcript,
                                 notice: groups.isEmpty || verifiedDigest == nil ? missing : notice,
                                 previewSize: size, previewItemCount: items,
                                 plan: verified ? verifiedDigest.map { CleanupPlan(ledgerDigest: $0, operationRows: operationRows(lines)) } : nil)
        }
    }

    // The CLI writes a human-readable list shared with Terminal. Only accept a
    // recent regular file matching this run's summary. Paths stay display-only.
    private static func recentLedger(_ url: URL, started: Date) -> String? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        let limit = 8 * 1024 * 1024
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= limit,
              Double(info.st_mtimespec.tv_sec + 1) >= started.timeIntervalSince1970,
              let bytes = try? handle.read(upToCount: limit + 1),
              bytes.count == info.st_size else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    private static func parseEntries(_ rows: [Substring]) -> ([PreviewGroup], Bool) {
        var groups: [PreviewGroup] = []
        var section: String?
        var index = 0
        let limit = 1_000
        for line in rows {
            if line.hasPrefix("=== "), line.hasSuffix(" ==="), line.count > 8 {
                section = String(line.dropFirst(4).dropLast(4))
                continue
            }
            guard let title = section, line.hasPrefix("/"),
                  let marker = line.range(of: "  # ", options: .backwards) else { continue }
            if index == limit { return (groups, true) }
            let entry = PreviewEntry(id: index, path: String(line[..<marker.lowerBound]),
                                     detail: String(line[marker.upperBound...]))
            if let existing = groups.firstIndex(where: { $0.title == title }) {
                groups[existing].entries.append(entry)
            } else {
                groups.append(PreviewGroup(title: title, entries: [entry]))
            }
            index += 1
        }
        return (groups, false)
    }
}
