import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension CleanupReport {
    func matchingGroups(_ query: String) -> [PreviewGroup] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.title.localizedCaseInsensitiveContains(term) ||
                sectionTitle(group.title).localizedCaseInsensitiveContains(term) {
                return group
            }
            let items = group.entries.filter {
                $0.path.localizedCaseInsensitiveContains(term) || $0.detail.localizedCaseInsensitiveContains(term) ||
                    $0.displayDetail.localizedCaseInsensitiveContains(term)
            }
            return items.isEmpty ? nil : PreviewGroup(title: group.title, entries: items)
        }
    }

    func matchingLogLines(_ query: String) -> [Substring] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.split(separator: "\n", omittingEmptySubsequences: false).filter {
            term.isEmpty || $0.localizedCaseInsensitiveContains(term)
        }
    }

    /// Export the immutable report as captured, including limits on its retained detail.
    func writeReport(titled title: String, to url: URL) throws {
        var lines = [title, summary]
        if let detailNotice { lines.append(detailNotice) }
        for group in groups {
            lines.append("")
            let count = group.entries.count
            lines.append(sectionTitle(group.title) + tr("（\(count) 条路径）", count == 1 ? " (1 path)" : " (\(count) paths)"))
            for item in group.entries {
                lines.append(item.path + "  " + item.displayDetail)
            }
        }
        lines += ["", tr("运行记录", "Run log")]
        if logClipped { lines.append(tr("（较早的输出已省略）", "(Earlier output omitted)")) }
        lines += [transcript, ""]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

struct ReportSheet: View {
    let heading: ReportText
    private var title: String { heading.value }
    let report: CleanupReport
    var cleanTiming: (() -> String)? = nil
    private var cleanTimingText: String? { cleanTiming?() }
    var confirmedClean: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var showingLog = false
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var confirming = false
    @State private var exportError: String?

    private var logVisible: Bool { showingLog || report.groups.isEmpty }
    private var filtering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @Environment(\.locale) private var locale
    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(report.summary).font(.subheadline).foregroundStyle(StrataColor.muted).textSelection(.enabled)
                }
                Spacer()
                Button(action: exportReport) { Label(tr("导出全部…", "Export all…"), systemImage: "square.and.arrow.up") }
                    .help(tr("存储本次报告的全部已载入明细和运行记录", "Save all loaded entries and the run log")).keyboardShortcut("s")
                Button(tr("完成", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let notice = report.detailNotice { Feedback(message: notice) }
            if let exportError { Feedback(message: tr("导出失败。", "Export failed. ") + exportError) }
            HStack(spacing: 12) {
                searchField
                if !report.groups.isEmpty {
                    Picker(tr("报告视图", "Report view"), selection: $showingLog) {
                        Text(tr("路径明细", "Paths")).tag(false)
                        Text(tr("运行记录", "Run log")).tag(true)
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            Group {
                if logVisible { logView }
                else { groupsView(report.matchingGroups(query)) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StrataColor.panel, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(StrataColor.border))
            if confirmedClean != nil {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if let cleanTimingText {
                            Label(cleanTimingText, systemImage: "clock").font(.callout)
                        }
                        Text(tr("整轮清理的范围由 Mole 重新扫描确定。", "Mole scans again to determine which items to remove."))
                            .font(.caption).foregroundStyle(StrataColor.muted)
                    }
                    Spacer()
                    Button(tr("执行整轮清理…", "Run full cleanup…")) { confirming = true }.buttonStyle(ActionStyle())
                }
            }
        }.padding(24)
            .frame(minWidth: 550, idealWidth: 690, minHeight: 380, idealHeight: 455)
            .foregroundStyle(StrataColor.ink).background(StrataColor.paper)
            .onAppear {
                if let first = report.groups.first { expanded.insert(first.id) }
            }
            .alert(tr("永久清理本机符合条件的项目？", "Permanently remove eligible items from this Mac?"), isPresented: $confirming) {
                Button(tr("取消", "Cancel"), role: .cancel) {}
                Button(tr("执行整轮清理", "Run full cleanup"), role: .destructive) { confirmedClean?() }
            } message: {
                Text((cleanTimingText.map { $0 + "\n\n" } ?? "") + tr("Mole 将重新扫描并按当前保护规则永久删除符合条件的项目，默认也会清空个人废纸篓。搜索仅筛选报告显示。实际范围可能与此预览不同。已有管理员授权时还可能处理系统缓存。已完成的删除无法撤销。", "Mole will scan again, permanently remove eligible items, and empty your Trash by default. Search filters only this report. The cleanup may differ from this preview and may include system caches if administrator access is already available. Deletions cannot be undone."))
            }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(StrataColor.muted)
                .help(tr("搜索报告（⌘F）", "Search report (⌘F)")).keyboardShortcut("f").accessibilityLabel(tr("搜索报告", "Search report"))
            TextField(logVisible ? tr("搜索运行记录", "Search run log") : tr("搜索路径、分组或大小", "Search paths, groups, or sizes"), text: $query)
                .textFieldStyle(.plain).focused($searchFocused)
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(StrataColor.muted).accessibilityLabel(tr("清除搜索", "Clear search"))
            }
        }.padding(.horizontal, 10).frame(height: 32)
            .background(StrataColor.rail, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(searchFocused ? StrataColor.accent : StrataColor.border))
    }

    @ViewBuilder
    private var logView: some View {
        if filtering {
            let lines = report.matchingLogLines(query)
            if lines.isEmpty { emptyResults }
            else { logText(lines.joined(separator: "\n"), count: lines.count) }
        } else {
            if report.logClipped {
                Text(tr("较早的输出已省略", "Earlier output omitted")).font(.caption).foregroundStyle(StrataColor.muted)
            }
            logText(report.transcript, count: nil)
        }
    }

    private func logText(_ text: String, count: Int?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let count {
                Text(tr("匹配 \(count) 行", count == 1 ? "1 matching line" : "\(count) matching lines")).font(.caption).foregroundStyle(StrataColor.muted)
                    .padding(.horizontal, 14).padding(.top, 10)
            }
            ScrollView {
                Text(verbatim: text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
    }

    @ViewBuilder
    private func groupsView(_ groups: [PreviewGroup]) -> some View {
        if groups.isEmpty { emptyResults }
        else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filtering {
                        let count = groups.reduce(0) { $0 + $1.entries.count }
                        Text(tr("匹配 \(count) 条路径", count == 1 ? "1 matching path" : "\(count) matching paths"))
                            .font(.caption).foregroundStyle(StrataColor.muted).padding(.top, 10)
                    }
                    ForEach(groups) { group in
                        let isOpen = filtering || expanded.contains(group.id)
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                if expanded.contains(group.id) { expanded.remove(group.id) }
                                else { expanded.insert(group.id) }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder").foregroundStyle(StrataColor.muted)
                                Text(sectionTitle(group.title)).font(.headline)
                                Spacer()
                                Text(tr("\(group.entries.count) 条", "\(group.entries.count)")).font(.caption.monospacedDigit())
                                    .foregroundStyle(StrataColor.muted)
                                if !filtering {
                                    Image(systemName: "chevron.right").font(.caption)
                                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                                }
                            }.padding(.vertical, 11).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(filtering)
                        if isOpen {
                            ForEach(group.entries) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(verbatim: item.path).font(.system(size: 12, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                    Text(verbatim: item.displayDetail).font(.caption.monospacedDigit())
                                        .foregroundStyle(StrataColor.muted).textSelection(.enabled)
                                }.padding(.leading, 21).padding(.vertical, 6)
                            }
                        }
                        Divider()
                    }
                }.padding(.horizontal, 14).padding(.vertical, 4)
            }
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(StrataColor.muted)
            Text(tr("没有匹配结果", "No results")).font(.headline)
            Button(tr("清除搜索", "Clear search")) { query = "" }
        }
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.title = tr("导出报告", "Export report")
        panel.nameFieldStringValue = "Strata-" + title + ".txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try report.writeReport(titled: title, to: url)
                exportError = nil
            } catch {
                exportError = error.localizedDescription
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: save) }
        else { panel.begin(completionHandler: save) }
    }
}
