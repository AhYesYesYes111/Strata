import AppKit
import SwiftUI

@MainActor
final class DiskModel: ObservableObject {
    @Published private(set) var location: URL?
    @Published private(set) var inventory: DiskScanResult?
    @Published private(set) var result: DiskScanResult?
    var displayedResult: DiskScanResult? { inventory ?? result }
    @Published private var failure: ScanFailure?
    var message: String? { failure?.description }

    private enum ScanFailure {
        case cancelled
        case save
        case selectFolder
        case read(NSError)

        var description: String {
            switch self {
            case .save:
                return tr("结果仅在本次打开时可用；无法保存快照。", "This result is available for this session only; the snapshot could not be saved.")
            case .selectFolder:
                return tr("请通过「选择文件夹」分析此位置。", "Use Choose Folder to measure this location.")
            case .cancelled:
                return tr("扫描已停止。", "Scan stopped.")
            case .read(let error):
                if error.domain == NSPOSIXErrorDomain {
                    switch Int32(error.code) {
                    case EACCES, EPERM:
                        return tr("此文件夹需要访问权限。", "Permission is needed to read this folder.")
                    case ENOENT:
                        return tr("此文件夹已不存在。", "This folder no longer exists.")
                    case ENOTDIR, ELOOP:
                        return tr("请选择一个实际文件夹。", "Choose a folder at its original location.")
                    default: break
                    }
                }
                return tr("无法读取此文件夹", "Couldn’t read this folder") + " (\(error.domain) \(error.code))."
            }
        }
    }
    @Published private(set) var running = false
    @Published private(set) var history: [URL] = []
    @Published private(set) var scanningName: String?
    private var work: Task<Void, Never>?
    private var request = UUID()
    private var ancestors: [DiskScanResult] = []
    @Published private(set) var startupVolume: VolumeReading?
    private(set) var wholeDisk = false

    private var selectedFolder: URL?
    private let snapshots: DiskSnapshots

    init(snapshots: DiskSnapshots = .shared) { self.snapshots = snapshots }
    var needsFolderSelection: Bool {
        if case .selectFolder = failure { return true }
        return false
    }

    func scan(_ url: URL, userSelected: Bool = false) {
        selectedFolder = userSelected ? url : nil
        wholeDisk = DiskScanner.directoryURL(url).path == DiskScanner.startupRoot.path
        startupVolume = wholeDisk ? VolumeReading.read() : nil
        ancestors.removeAll()
        history = []
        load(url)
    }

    func startIfNeeded() {
        if location == nil { scan(DiskScanner.startupRoot) }
    }

    func enter(_ url: URL) {
        guard !needsMusicSelection(url) else { return }
        guard let observed = displayedResult,
              observed.entries.contains(where: { $0.isDirectory && !$0.requiresSelection && $0.url == url }) else { return }
        if let result {
            ancestors.append(result)
            if ancestors.count > 6 { ancestors.removeFirst() }
        }
        history.append(observed.root)
        if let cached = observed.children[url] {
            cancel()
            location = url
            result = DiskScanResult(root: url, entries: cached, isPartial: false, measuredAt: observed.measuredAt)
            failure = nil
        } else { load(url) }
    }

    func needsMusicSelection(_ url: URL) -> Bool {
        DiskScanPrivacy().needsSelection(url, selectedFolder: selectedFolder, musicOnly: true)
    }

    func back() {
        if let last = history.indices.last { jump(to: last) }
    }

    func jump(to index: Int) {
        guard history.indices.contains(index) else { return }
        let prior = history[index]
        history.removeSubrange(index...)
        if let cached = ancestors.lastIndex(where: { $0.root == prior }) {
            let snapshot = ancestors[cached]
            ancestors.removeSubrange(cached...)
            cancel()
            location = snapshot.root
            result = snapshot
            failure = nil
        } else {
            ancestors.removeAll()
            load(prior)
        }
    }

    func refresh() {
        if wholeDisk { startupVolume = VolumeReading.read() }
        if let location { load(location, refresh: true) }
    }

    func cancel() {
        request = UUID()
        work?.cancel()
        work = nil
        if running, result == nil, let inventory { result = inventory }
        inventory = nil
        scanningName = nil
        if running {
            running = false
            failure = .cancelled
        }
    }

    private func load(_ url: URL, refresh: Bool = false) {
        work?.cancel()
        let ticket = UUID()
        request = ticket
        location = DiskScanner.directoryURL(url)
        if !refresh || result?.measuredAt == nil { result = nil }
        inventory = nil
        failure = nil
        scanningName = nil
        running = true
        let scanStartup = wholeDisk
        let selection = selectedFolder
        let scope = DiskSnapshots.Scope(root: DiskScanner.directoryURL(url), wholeDisk: scanStartup, selection: selection)
        work = Task { [self] in
            defer {
                if request == ticket {
                    running = false
                    inventory = nil
                    scanningName = nil
                    work = nil
                }
            }
            if !refresh, !DiskScanPrivacy().needsSelection(scope.root, selectedFolder: selection),
               let saved = await snapshots.read(scope) {
                guard request == ticket, !Task.isCancelled else { return }
                result = saved
                return
            }
            guard request == ticket, !Task.isCancelled else { return }
            do {
                var report = try await DiskScanner.scan(url, wholeDisk: scanStartup, selectedFolder: selection, onInventory: { snapshot in
                    Task { @MainActor in
                        guard self.running, self.request == ticket, snapshot.sequence > (self.inventory?.sequence ?? 0) else { return }
                        self.inventory = snapshot
                    }
                }) { [weak self] name in
                    Task { @MainActor in
                        guard let self, self.running, self.request == ticket else { return }
                        self.scanningName = name
                    }
                }
                guard request == ticket, !Task.isCancelled else { return }
                report.measuredAt = Date()
                inventory = report
                result = report
                do { try await snapshots.save(report, for: scope) }
                catch {
                    if request == ticket, !Task.isCancelled { failure = .save }
                }
            } catch {
                guard request == ticket, !Task.isCancelled else { return }
                failure = error is DiskScanAccessError ? .selectFolder : .read(error as NSError)
            }
        }
    }
}

enum DiskItemKind: CaseIterable {
    case all, directories, files

    var title: String {
        switch self {
        case .all: return tr("全部项目", "All items")
        case .directories: return tr("文件夹", "Folders")
        case .files: return tr("非文件夹", "Files")
        }
    }
}

enum DiskItemOrder: CaseIterable {
    case largest, smallest, name

    var title: String {
        switch self {
        case .largest: return tr("占用从大到小", "Largest first")
        case .smallest: return tr("占用从小到大", "Smallest first")
        case .name: return tr("名称顺序", "Name")
        }
    }
}

struct DiskListOptions {
    var query = ""
    var kind = DiskItemKind.all
    var order = DiskItemOrder.largest

    func visible(in result: DiskScanResult) -> [DiskEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries = result.entries
        if !term.isEmpty || kind != .all {
            entries = entries.filter { entry in
                if kind == .directories && !entry.isDirectory { return false }
                if kind == .files && entry.isDirectory { return false }
                return term.isEmpty || entry.name.localizedStandardContains(term)
            }
        }
        // The scanner already supplies largest-first order, with stable name ties.
        guard order != .largest else { return entries }
        return entries.sorted { first, second in
            if order == .smallest && first.bytes != second.bytes { return first.bytes < second.bytes }
            let comparison = first.name.localizedStandardCompare(second.name)
            return comparison == .orderedSame ? first.name < second.name : comparison == .orderedAscending
        }
    }
}

struct AnalyzePage: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: DiskModel
    @State private var options = DiskListOptions()
    @State private var tileOffset = 0
    @State private var hovered: URL?
    @State private var selectedTile: URL?

    var body: some View {
        let _ = locale
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 18) {
                sidebar.frame(width: max(196, min(254, geometry.size.width * 0.23)))
                VStack(spacing: 10) {
                    navigation
                    mapContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.running {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            let pending = model.inventory?.pendingDirectories ?? 0
                            Text(pending > 0
                                 ? tr("正在测量 · 还剩 \(pending) 个文件夹", "Sizing · \(pending) folder" + (pending == 1 ? "" : "s") + " remaining")
                                 : tr("正在读取目录…", "Reading folders…"))
                            Spacer()
                        }.font(.caption).foregroundStyle(StrataColor.muted)
                    } else if let result = model.result {
                        HStack {
                            Image(systemName: result.isPartial ? "exclamationmark.circle" : "square.grid.2x2")
                            Text(model.message ?? (result.isPartial ? tr("部分结果 · 权限、扫描上限或跨卷项目可能影响总量。", "Partial results. Some items could not be measured.") : tr("面积按分配空间计算，APFS 克隆可能共享数据块。", "Tiles show allocated space. APFS clones can share blocks.")))
                            Spacer()
                            let remainder = result.entries.prefix { $0.bytes > 0 }.count - tileOffset - TileMap.pageSize
                            if remainder > 0 {
                                Button { tileOffset += TileMap.pageSize } label: {
                                    Label(tr("其余 \(remainder) 项", "\(remainder) more"), systemImage: "square.grid.2x2")
                                }.help(tr("放大查看其余项目", "Explore remaining items")).fixedSize()
                            }
                        }.font(.caption).foregroundStyle(StrataColor.muted)
                    }
                }
            }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
        }.onAppear { model.startIfNeeded() }
            .onChange(of: model.location) { _ in
                options = DiskListOptions(order: options.order)
                tileOffset = 0
                hovered = nil
            }
            .onChange(of: model.running) { running in
                if running { tileOffset = 0; hovered = nil }
            }
            .onChange(of: model.result?.entries.count) { _ in
                let count = model.result?.entries.prefix { $0.bytes > 0 }.count ?? 0
                if tileOffset >= count { tileOffset = 0 }
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                Image(systemName: "internaldrive").font(.system(size: 23, weight: .medium))
                    .foregroundStyle(StrataColor.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("磁盘分析", "Disk usage")).font(.system(size: 21, weight: .semibold))
                    if let result = model.displayedResult {
                        Text(tr("\(result.entries.count) 项", result.entries.count == 1 ? "1 item" : "\(result.entries.count) items") + " · " + measuredSize(result.totalBytes, partial: result.isPartial))
                            .lineLimit(1).minimumScaleFactor(0.8).monospacedDigit()
                            .font(.caption).foregroundStyle(StrataColor.muted)
                    } else {
                        Text(model.running ? tr("读取分配空间…", "Measuring space…") : tr("当前文件夹", "Current folder")).font(.caption).foregroundStyle(StrataColor.muted)
                    }
                }
            }.padding(.top, 4)
            if let date = model.displayedResult?.measuredAt {
                Text(tr("上次扫描：", "Last scan: ") + date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
                    .font(.caption).foregroundStyle(StrataColor.muted)
            }
            if model.wholeDisk, let volume = model.startupVolume, model.location?.path == "/" {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("磁盘已用", "Disk used")).font(.caption).foregroundStyle(StrataColor.muted)
                    Text(storageSize(volume.used) + " / " + storageSize(volume.capacity))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    ProgressView(value: volume.fraction).progressViewStyle(.linear).tint(StrataColor.accent)
                }.help(tr("系统报告的启动磁盘占用。文件总量按可读取的目录单独测量。",
                          "Startup disk usage reported by macOS. File totals are measured separately in readable folders."))
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(StrataColor.muted)
                TextField(tr("搜索当前目录", "Search this folder"), text: $options.query).textFieldStyle(.plain)
                if !options.query.isEmpty {
                    Button { options.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel(tr("清除搜索", "Clear search"))
                }
            }.padding(.horizontal, 9).frame(height: 31)
                .background(StrataColor.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StrataColor.border))
            HStack {
                Text(tr("当前目录", "This folder")).font(.system(size: 12, weight: .semibold)).foregroundStyle(StrataColor.muted)
                Spacer()
                Menu {
                    Picker(tr("类型", "Kind"), selection: $options.kind) {
                        ForEach(DiskItemKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Picker(tr("排序", "Sort by"), selection: $options.order) {
                        ForEach(DiskItemOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(options.kind == .all ? tr("筛选与排序", "Filter & sort") : options.kind.title, systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                }.menuStyle(.borderlessButton).fixedSize().help(tr("筛选与排序", "Filter & sort"))
            }
            if let result = model.displayedResult {
                entries(result)
            } else {
                Spacer()
            }
        }
        .padding(.trailing, 12)
        .overlay(alignment: .trailing) { Rectangle().fill(StrataColor.border).frame(width: 1) }
    }

    private func entries(_ result: DiskScanResult) -> some View {
        let filtered = options.visible(in: result)
        return VStack(alignment: .leading, spacing: 6) {
            if filtered.count != result.entries.count {
                Text(tr("显示 \(filtered.count) / \(result.entries.count) 项", "Showing \(filtered.count) of \(result.entries.count)")).font(.caption).foregroundStyle(StrataColor.muted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(filtered) { entry in
                        Button { open(entry) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: entry.requiresSelection ? "lock" : (entry.isDirectory ? "folder" : "doc"))
                                    .frame(width: 18).foregroundStyle(StrataColor.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: entry.name).font(.system(size: 13, weight: .medium))
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(entry.requiresSelection ? tr("选择后测量", "Choose to measure") : measuredSize(entry.bytes, partial: entry.isPartial))
                                        .font(.caption).monospacedDigit().foregroundStyle(StrataColor.muted)
                                }
                                Spacer(minLength: 2)
                                Image(systemName: entry.isDirectory ? "chevron.right" : "arrow.up.forward")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }.padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(.white.opacity(hovered == entry.url ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 7))
                            .onHover { setHover($0, url: entry.url) }
                            .help(entry.url.path)
                            .contextMenu { Button(tr("在访达中显示", "Show in Finder")) { reveal(entry.url) } }
                    }
                    if filtered.isEmpty && !result.entries.isEmpty {
                        Text(tr("没有匹配的项目", "No matching items")).font(.caption).foregroundStyle(StrataColor.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            Button {
                if tileOffset > 0 { tileOffset = max(0, tileOffset - TileMap.pageSize) }
                else { model.back() }
            } label: { Image(systemName: "chevron.left").frame(width: 19, height: 22) }
                .disabled(model.history.isEmpty && tileOffset == 0)
                .buttonStyle(.plain).accessibilityLabel(tr("返回上一级", "Go up one level"))
            if let location = model.location {
                ViewThatFits(in: .horizontal) {
                    breadcrumbs(location)
                    Menu {
                        ForEach(model.history.indices, id: \.self) { i in
                            Button(folderName(model.history[i])) { model.jump(to: i) }
                        }
                        Button(location.path) { tileOffset = 0 }
                    } label: {
                        Text(folderName(location)).lineLimit(1).truncationMode(.middle)
                    }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 3)
            Menu {
                Button(tr("整个磁盘", "Whole Disk")) { model.scan(DiskScanner.startupRoot) }
                Button(tr("个人文件夹", "Home")) { model.scan(FileManager.default.homeDirectoryForCurrentUser) }
                Divider()
                Button(tr("选择文件夹…", "Choose folder…")) { chooseFolder() }
            } label: { Label(tr("位置", "Location"), systemImage: "folder") }
                .menuStyle(.borderlessButton).fixedSize().help(tr("切换分析位置", "Choose a location"))
            Button {
                if model.running { model.cancel() } else { model.refresh() }
            } label: { Image(systemName: model.running ? "stop.circle" : "arrow.clockwise").frame(width: 22, height: 22) }
                .buttonStyle(.plain).accessibilityLabel(model.running ? tr("取消扫描", "Cancel scan") : tr("重新扫描", "Scan again"))
                .help(model.running ? tr("取消扫描", "Cancel scan") : tr("重新扫描", "Scan again"))
        }.font(.system(size: 13)).frame(height: 29)
    }

    private func breadcrumbs(_ location: URL) -> some View {
        HStack(spacing: 6) {
            ForEach(model.history.indices, id: \.self) { index in
                Button(folderName(model.history[index])) { model.jump(to: index) }.buttonStyle(.plain)
                    .foregroundStyle(StrataColor.muted)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if tileOffset > 0 {
                Button(folderName(location)) { tileOffset = 0 }.buttonStyle(.plain)
                Image(systemName: "chevron.right").font(.system(size: 9))
                Text(tr("其余项目", "More items"))
            } else { Text(folderName(location)).fontWeight(.semibold) }
        }.fixedSize().help(location.path)
    }

    @ViewBuilder private var mapContent: some View {
        if let result = model.displayedResult, result.totalBytes > 0 {
            TileMap(result: result, offset: tileOffset, nested: !model.history.isEmpty, hovered: hovered,
                    selected: selectedTile, open: open,
                    more: { tileOffset += TileMap.pageSize }, hover: setHover)
                .id(tileOffset)
                .id(result.root)
        } else {
            VStack(spacing: 12) {
                if model.running {
                    ProgressView().controlSize(.small)
                    Text(model.scanningName.map { tr("正在分析“\($0)”", "Scanning “\($0)”") } ?? tr("正在分析文件夹…", "Scanning folder…"))
                        .font(.headline).lineLimit(2)
                } else {
                    Image(systemName: "folder").font(.largeTitle).foregroundStyle(StrataColor.accent)
                    Text(model.message ?? (model.result?.entries.isEmpty == true && model.result?.isPartial == false
                         ? tr("文件夹为空", "This folder is empty") : tr("没有已测得的分配空间", "No allocated space was measured"))).font(.headline)
                    if model.needsFolderSelection {
                        Button(tr("选择文件夹…", "Choose folder…")) { chooseFolder(startingAt: model.location) }
                    } else if model.message != nil { Button(tr("重新扫描", "Scan again"), action: model.refresh) }
                }
            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StrataColor.panel, in: RoundedRectangle(cornerRadius: 13))
        }
    }

    private func open(_ entry: DiskEntry) {
        selectedTile = entry.url
        if entry.requiresSelection || model.needsMusicSelection(entry.url) { chooseFolder(startingAt: entry.url) }
        else if entry.isDirectory { model.enter(entry.url) }
        else { reveal(entry.url) }
    }

    private func setHover(_ inside: Bool, url: URL) {
        if inside { hovered = url } else if hovered == url { hovered = nil }
    }

    private func folderName(_ url: URL) -> String {
        if url.path == DiskScanner.startupRoot.path { return tr("整个磁盘", "Whole Disk") }
        if url == FileManager.default.homeDirectoryForCurrentUser { return tr("个人文件夹", "Home") }
        return url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
    }

    private func chooseFolder(startingAt requested: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = tr("选择要分析的文件夹", "Choose a folder to analyze")
        panel.prompt = tr("分析", "Analyze")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = (requested ?? model.location).map { DiskScanPrivacy().pickerStart(for: $0) }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { model.scan(url, userSelected: true) }
            }
        } else {
            panel.begin { response in
                if response == .OK, let url = panel.url { model.scan(url, userSelected: true) }
            }
        }
    }
}

private func measuredSize(_ bytes: Int64, partial: Bool) -> String {
    (partial ? "≥ " : "") + storageSize(bytes)
}

private struct MapItem: Identifiable {
    enum ID: Hashable {
        case entry(URL)
        case remainder(Int)
    }
    let id: ID
    let tone: TreemapTone
    let name: String
    let bytes: Int64
    let partial: Bool
    let entry: DiskEntry?
}

private struct MapCell: Identifiable {
    let item: MapItem
    let rect: CGRect
    var id: MapItem.ID { item.id }
}

struct TreemapTone: Equatable {
    let rgb: Int
    private static let categories = ["Users": 0x4A4B4F, "Applications": 0x3D3F43, "System": 0x44464A,
                                     "private": 0x383A3E, "Library": 0x424448, "opt": 0x3C3E42]
    static let gutter = Self(rgb: 0x171719)
    static let outline = Self(rgb: 0xB7BAC1)

    static func region(_ url: URL) -> Self {
        var parts = url.path.split(separator: "/")[...]
        if parts.starts(with: ["System", "Volumes", "Data"]) { parts = parts.dropFirst(3) }
        let base = parts.first.flatMap { categories[String($0)] } ?? 0x404246
        guard parts.count > 1, let name = parts.last else { return Self(rgb: base) }
        let shift = name.utf8.reduce(0) { (31 * $0 + Int($1)) % 9 } - 4
        return Self(rgb: base + shift * 0x010101)
    }

    func color(hovered: Bool = false) -> Color {
        let factor = (hovered ? 1.11 : 1.0) / 255
        return Color(.sRGB, red: Double(rgb >> 16) * factor,
                     green: Double((rgb >> 8) & 255) * factor, blue: Double(rgb & 255) * factor)
    }
}

struct TileMap: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @FocusState private var focused: MapItem.ID?
    @State private var hoveredRemainder = false
    @State private var partition: TreemapLayout<MapItem.ID>.Partition?
    let result: DiskScanResult
    let offset: Int
    let nested: Bool
    let hovered: URL?
    let selected: URL?
    let open: (DiskEntry) -> Void
    let more: () -> Void
    let hover: (Bool, URL) -> Void
    static let pageSize = 12

    private var items: [MapItem] {
        let positive = result.entries.prefix { $0.bytes > 0 }.dropFirst(offset)
        let shown = positive.prefix(Self.pageSize)
        var tiles = shown.map { entry in
            MapItem(id: .entry(entry.url), tone: TreemapTone.region(entry.url), name: entry.name, bytes: entry.bytes, partial: entry.isPartial, entry: entry)
        }
        let rest = positive.dropFirst(shown.count)
        if !rest.isEmpty {
            tiles.append(MapItem(id: .remainder(offset), tone: TreemapTone.region(result.root), name: tr("其余 \(rest.count) 项", "\(rest.count) more"),
                                 bytes: rest.reduce(0) { $0 + $1.bytes }, partial: rest.contains(where: \.isPartial), entry: nil))
        }
        return tiles
    }

    var body: some View {
        let _ = locale
        let tiles = items
        GeometryReader { geometry in
            let layout = TreemapLayout(tiles.map { (id: $0.id, bytes: $0.bytes) },
                                       in: CGRect(origin: .zero, size: geometry.size), keeping: partition)
            let cells = tiles.compactMap { item in layout.frames[item.id].map { MapCell(item: item, rect: $0) } }
            ZStack(alignment: .topLeading) {
                ForEach(cells) { cell in
                    tile(cell.item)
                        .frame(width: max(0, cell.rect.width - 3 / displayScale),
                               height: max(0, cell.rect.height - 3 / displayScale))
                        .transition(reduceMotion ? .identity : .opacity)
                        .position(x: cell.rect.midX, y: cell.rect.midY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(TreemapTone.gutter.color())
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.55, dampingFraction: 1, blendDuration: 0.18),
                       value: result.sequence)
            .overlay(alignment: .topLeading) {
                if let focused, let cell = cells.first(where: { $0.id == focused }) {
                    focusTip(cell, in: geometry.size)
                }
            }
            .onAppear { partition = layout.partition }
            .onChange(of: layout.partition) { partition = $0 }
        }
    }

    private func detail(_ item: MapItem) -> String {
        item.name + " · " + measuredSize(item.bytes, partial: item.partial)
    }

    private func focusTip(_ cell: MapCell, in viewport: CGSize) -> some View {
        Text(verbatim: detail(cell.item))
            .font(.caption).foregroundStyle(.white).lineLimit(3)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(TreemapTone.gutter.color(), in: RoundedRectangle(cornerRadius: 4))
            .alignmentGuide(.leading) { tip in
                -max(0, min(cell.rect.midX - tip.width / 2, viewport.width - tip.width))
            }
            .alignmentGuide(.top) { tip in
                let below = cell.rect.maxY + 3
                return -(below + tip.height <= viewport.height ? below : max(0, cell.rect.minY - tip.height - 3))
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func tile(_ item: MapItem) -> some View {
        let highlighted = item.entry.map { hovered == $0.url } ?? hoveredRemainder
        let isSelected = item.entry.map { selected == $0.url } ?? false
        let icon = item.entry.map { $0.isDirectory ? "folder" : "doc" } ?? "square.grid.2x2"
        let shape = RoundedRectangle(cornerRadius: (nested ? 4 : 8) / displayScale, style: .continuous)
        return Button {
            if let entry = item.entry { open(entry) } else { more() }
        } label: {
            shape.fill(item.tone.color(hovered: highlighted))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: highlighted)
                .overlay {
                    ViewThatFits {
                        VStack(spacing: 4) {
                            HStack(spacing: 5) {
                                Image(systemName: icon)
                                Text(verbatim: item.name)
                            }.font(.system(size: 13, weight: .semibold))
                            Text(measuredSize(item.bytes, partial: item.partial))
                                .font(.system(size: 12, design: .rounded)).monospacedDigit()
                        }.fixedSize()
                        Text(verbatim: item.name).font(.system(size: 12, weight: .semibold)).fixedSize()
                        Image(systemName: icon).font(.system(size: 12)).fixedSize()
                        Color.clear
                    }.padding(5).foregroundStyle(.white)
                }
                .clipShape(shape).contentShape(shape)
        }.buttonStyle(TileSelectionStyle(shape: shape, outlined: isSelected || focused == item.id, width: 1.5 / displayScale))
            .focused($focused, equals: item.id)
            .onHover { inside in
                if let entry = item.entry { hover(inside, entry.url) } else { hoveredRemainder = inside }
            }
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityLabel(detail(item))
            .accessibilityHint(item.entry?.isDirectory == false ? tr("在访达中显示", "Show in Finder") : tr("打开并查看内容", "Open to explore contents"))
            .help(detail(item))
            .contextMenu {
                if let entry = item.entry { Button(tr("在访达中显示", "Show in Finder")) { reveal(entry.url) } }
            }
    }

    private struct TileSelectionStyle: ButtonStyle {
        let shape: RoundedRectangle
        let outlined: Bool
        let width: CGFloat

        func makeBody(configuration: Configuration) -> some View {
            configuration.label.overlay {
                if outlined || configuration.isPressed {
                    shape.strokeBorder(TreemapTone.outline.color(), lineWidth: width).allowsHitTesting(false)
                }
            }
        }
    }

}
