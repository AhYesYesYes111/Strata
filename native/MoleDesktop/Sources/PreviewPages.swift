import AppKit
import SwiftUI

@MainActor
final class PreviewModel: ObservableObject {
    let kind: PreviewKind
    @Published private(set) var running = false
    @Published private(set) var applying = false
    @Published private(set) var didClean = false
    @Published private var activeSection = ""
    var stage: String { sectionTitle(activeSection) }
    @Published private(set) var report: CleanupReport?
    @Published private var failure: ReportText?
    var message: String? { failure?.value }
    @Published private(set) var volume: VolumeReading?
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var timings = CleanTimingHistory()
    private var startUptime: TimeInterval = 0
    private var sectionOffsets: [String: TimeInterval] = [:]

    var elapsed: TimeInterval { max(0, ProcessInfo.processInfo.systemUptime - startUptime) }
    var scanEstimate: CleanTimeEstimate { timings.estimate(.scan) }
    var cleanEstimate: CleanTimeEstimate { timings.estimate(.clean) }
    var cleanTimingText: String { tr("清理约 ", "Estimated cleanup · ") + cleanEstimate.rangeText + " · " + cleanEstimate.basis }
    var activeEstimate: CleanTimeEstimate {
        timings.estimate(applying ? .clean : .scan, section: activeSection, entered: sectionOffsets[activeSection] ?? 0)
    }

    init(kind: PreviewKind) { self.kind = kind }

    func refreshVolume() {
        if kind == .clean { volume = VolumeReading.read() }
    }
    func start() { run(approval: nil) }

    func applyAfterConfirmation() {
        guard kind == .clean, let report, report.canApplyClean else { return }
        run(approval: report)
    }

    private func run(approval: CleanupReport?) {
        guard !running else { return }
        let ticket = UUID()
        generation = ticket
        startedAt = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        sectionOffsets.removeAll(keepingCapacity: true)
        activeSection = ""
        finishedAt = nil
        running = true
        applying = approval != nil
        didClean = false
        report = nil
        failure = nil
        refreshVolume()
        let progress: @Sendable (String) -> Void = { [weak self] section in
            Task { @MainActor in
                guard let self, self.running, self.generation == ticket else { return }
                if CleanRunTiming.knownSections.contains(section), self.sectionOffsets[section] == nil {
                    self.sectionOffsets[section] = self.elapsed
                }
                self.activeSection = section
            }
        }
        work = Task {
            defer {
                finishedAt = Date()
                running = false
                applying = false
                work = nil
                refreshVolume()
            }
            do {
                if let plan = approval?.plan {
                    let result = try await CleanupPreview.applyConfirmedClean(plan, onProgress: progress)
                    report = result
                    didClean = result.completedClean
                    if !didClean {
                        failure = ReportText("清单已更新。请查看最新扫描结果并重新确认。",
                                             "The cleanup list changed. Review the latest scan before confirming again.")
                        return
                    }
                } else {
                    let result = try await CleanupPreview.run(kind, onProgress: progress)
                    try Task.checkCancellation()
                    report = result
                }
                if kind == .clean, !Task.isCancelled {
                    let sample = CleanRunTiming(seconds: elapsed, sections: sectionOffsets, completed: Date())
                    timings.record(sample, for: didClean ? .clean : .scan)
                }
            } catch {
                failure = approval == nil && Task.isCancelled ? ReportText("扫描已取消。", "Scan canceled.") : ReportText(error)
            }
        }
    }

    func cancel() { work?.cancel() }
}

struct Feedback: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "info.circle").font(.system(size: 13)).foregroundStyle(StrataColor.muted)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MaintenancePage: View {
    @ObservedObject var model: PreviewModel
    @State private var showingReport = false
    @Environment(\.locale) private var locale
    var body: some View {
        let _ = locale
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageTitle(tr("系统维护", "Maintenance"), detail: tr("查看开源引擎建议执行的 macOS 维护任务。", "Review maintenance tasks for this Mac."))
                Panel {
                    VStack(alignment: .leading, spacing: 15) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 22, weight: .medium))
                            .foregroundStyle(StrataColor.ink).frame(width: 44, height: 44)
                            .background(StrataColor.rail, in: RoundedRectangle(cornerRadius: 12))
                        Text(tr("维护预检", "Maintenance check")).font(.title2.weight(.semibold))
                        Text(tr("检查缓存、系统服务和数据库的维护条件。本次预检保留系统设置。", "Check caches, system services, and databases for maintenance opportunities.")).font(.body).foregroundStyle(StrataColor.muted)
                        if model.running {
                            HStack { ProgressView().controlSize(.small); Text(model.stage); Button(tr("取消预检", "Cancel check"), action: model.cancel) }
                        } else {
                            HStack {
                                Button(model.report == nil ? tr("开始预检", "Run check") : tr("重新预检", "Check again"), action: model.start)
                                    .buttonStyle(ActionStyle(isPrimary: true))
                                if model.report != nil {
                                    Button(tr("查看报告", "View report")) { showingReport = true }.buttonStyle(ActionStyle())
                                }
                            }
                        }
                        if let report = model.report { Text(report.summary).textSelection(.enabled) }
                        if let message = model.message { Feedback(message: message) }
                    }
                }
            }.frame(maxWidth: 1250).padding(26).frame(maxWidth: .infinity)
        }.sheet(isPresented: $showingReport) {
            if let report = model.report { ReportSheet(heading: ReportText("维护预检报告", "Maintenance report"), report: report) }
        }
    }
}

func sectionTitle(_ name: String) -> String {
    let labels = [
        "System": "系统缓存", "User essentials": "用户缓存与日志", "App caches": "应用缓存",
        "Browsers": "浏览器", "Cloud & Office": "云服务与办公软件", "Developer tools": "开发工具",
        "Apps & utilities": "应用与实用工具", "Virtualization": "虚拟化工具",
        "Application Support": "应用支持文件", "App leftovers": "卸载残留",
        "Device backups & firmware": "设备备份与固件", "Large files": "大文件",
        "Project artifacts": "项目构建产物", "External volume": "外置卷", "User caches": "用户缓存",
        "Apple Silicon updates": "Apple 芯片更新", "Time Machine": "时间机器"
    ]
    return tr(labels[name] ?? name, name)
}
