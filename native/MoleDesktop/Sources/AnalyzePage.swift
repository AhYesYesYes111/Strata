import AppKit
import SwiftUI

@MainActor
final class DiskModel: ObservableObject {
    @Published private(set) var location: URL?
    @Published private(set) var inventory: DiskScanResult?
    @Published private(set) var result: DiskScanResult?
    @Published private var failure: ScanFailure?
    var message: String? { failure?.description }

    private enum ScanFailure {
        case cancelled
        case selectFolder
        case read(NSError)

        var description: String {
            switch self {
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
        guard let observed = result ?? inventory,
              observed.entries.contains(where: { $0.isDirectory && !$0.requiresSelection && $0.url == url }) else { return }
        if let result {
            ancestors.append(result)
            if ancestors.count > 6 { ancestors.removeFirst() }
        }
        history.append(observed.root)
        if let cached = observed.children[url] {
            cancel()
            location = url
            result = DiskScanResult(root: url, entries: cached, isPartial: false)
            failure = nil
        } else { load(url) }
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
        if let location { load(location) }
    }

    func cancel() {
        request = UUID()
        work?.cancel()
        work = nil
        if running, let inventory { result = inventory }
        inventory = nil
        scanningName = nil
        if running {
            running = false
            failure = .cancelled
        }
    }

    private func load(_ url: URL) {
        work?.cancel()
        let ticket = UUID()
        request = ticket
        location = DiskScanner.directoryURL(url)
        result = nil
        inventory = nil
        failure = nil
        scanningName = nil
        running = true
        let scanStartup = wholeDisk
        let selection = selectedFolder
        work = Task { [self] in
            do {
                let report = try await DiskScanner.scan(url, wholeDisk: scanStartup, selectedFolder: selection, onInventory: { snapshot in
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
                guard !Task.isCancelled else { return }
                result = report
            } catch {
                guard !Task.isCancelled else { return }
                failure = error is DiskScanAccessError ? .selectFolder : .read(error as NSError)
            }
            running = false
            inventory = nil
            scanningName = nil
            work = nil
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

    private let warm = Color(red: 0.91, green: 0.74, blue: 0.55)

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
                    .foregroundStyle(warm)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("磁盘分析", "Disk usage")).font(.system(size: 21, weight: .semibold))
                    if let result = model.result ?? model.inventory {
                        Text(tr("\(result.entries.count) 项", result.entries.count == 1 ? "1 item" : "\(result.entries.count) items") + " · " + measuredSize(result.totalBytes, partial: result.isPartial))
                            .lineLimit(1).minimumScaleFactor(0.8).monospacedDigit()
                            .font(.caption).foregroundStyle(StrataColor.muted)
                    } else {
                        Text(model.running ? tr("读取分配空间…", "Measuring space…") : tr("当前文件夹", "Current folder")).font(.caption).foregroundStyle(StrataColor.muted)
                    }
                }
            }.padding(.top, 4)
            if model.wholeDisk, let volume = model.startupVolume, model.location?.path == "/" {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("磁盘已用", "Disk used")).font(.caption).foregroundStyle(StrataColor.muted)
                    Text(storageSize(volume.used) + " / " + storageSize(volume.capacity))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    ProgressView(value: volume.fraction).progressViewStyle(.linear).tint(warm)
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
            if let result = model.result ?? model.inventory {
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
                                    .frame(width: 18).foregroundStyle(warm)
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
        if let result = model.result ?? model.inventory, result.totalBytes > 0 {
            TileMap(result: result, offset: tileOffset, hovered: hovered, open: open,
                    more: { tileOffset += TileMap.pageSize }, hover: setHover)
        } else {
            VStack(spacing: 12) {
                if model.running {
                    ProgressView().controlSize(.small)
                    Text(model.scanningName.map { tr("正在分析“\($0)”", "Scanning “\($0)”") } ?? tr("正在分析文件夹…", "Scanning folder…"))
                        .font(.headline).lineLimit(2)
                } else {
                    Image(systemName: "folder").font(.largeTitle).foregroundStyle(warm)
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
        if entry.requiresSelection { chooseFolder(startingAt: entry.url) }
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
        panel.directoryURL = requested ?? model.location
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
    let colorIndex: Int
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

private struct TileMap: View {
    @Environment(\.locale) private var locale
    let result: DiskScanResult
    let offset: Int
    let hovered: URL?
    let open: (DiskEntry) -> Void
    let more: () -> Void
    let hover: (Bool, URL) -> Void
    static let pageSize = 12

    private static let fills = [
        Color(red: 0.54, green: 0.36, blue: 0.29), Color(red: 0.55, green: 0.39, blue: 0.19),
        Color(red: 0.59, green: 0.32, blue: 0.23), Color(red: 0.36, green: 0.41, blue: 0.37),
        Color(red: 0.40, green: 0.35, blue: 0.43), Color(red: 0.35, green: 0.42, blue: 0.49),
        Color(red: 0.49, green: 0.39, blue: 0.32), Color(red: 0.38, green: 0.36, blue: 0.28)
    ]

    private var items: [MapItem] {
        let positive = result.entries.prefix { $0.bytes > 0 }.dropFirst(offset)
        let shown = positive.prefix(Self.pageSize)
        var tiles = shown.enumerated().map { i, entry in
            MapItem(id: .entry(entry.url), colorIndex: entry.tileColorIndex ?? (offset + i), name: entry.name, bytes: entry.bytes, partial: entry.isPartial, entry: entry)
        }
        let rest = positive.dropFirst(shown.count)
        if !rest.isEmpty {
            tiles.append(MapItem(id: .remainder(offset), colorIndex: 0, name: tr("其余 \(rest.count) 项", "\(rest.count) more"),
                                 bytes: rest.reduce(0) { $0 + $1.bytes }, partial: rest.contains(where: \.isPartial), entry: nil))
        }
        return tiles
    }

    var body: some View {
        let _ = locale
        let tiles = items
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Self.layout(tiles[...], in: CGRect(origin: .zero, size: geometry.size))) { cell in
                    let width = max(0, cell.rect.width - 2)
                    let height = max(0, cell.rect.height - 2)
                    tile(cell).frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: min(8, width / 5, height / 5)))
                        .position(x: cell.rect.midX, y: cell.rect.midY)
                }
            }
        }
    }

    private func tile(_ cell: MapCell) -> some View {
        let item = cell.item
        let highlighted = item.entry != nil && hovered == item.entry?.url
        let tileColor = item.entry == nil ? Color(red: 0.34, green: 0.34, blue: 0.34) : Self.fills[item.colorIndex % Self.fills.count]
        return Button {
            if let entry = item.entry { open(entry) } else { more() }
        } label: {
            ZStack {
                tileColor
                if highlighted { Color.white.opacity(0.12) }
                if cell.rect.width >= 28 && cell.rect.height >= 22 {
                    VStack(spacing: 4) {
                        let icon = item.entry.map { $0.isDirectory ? "folder" : "doc" } ?? "square.grid.2x2"
                        if cell.rect.width >= 72 && cell.rect.height >= 48 {
                            HStack(spacing: 5) {
                                Image(systemName: icon)
                                Text(verbatim: item.name).lineLimit(1).truncationMode(.middle)
                            }.font(.system(size: cell.rect.width > 160 ? 15 : 12, weight: .semibold))
                            Text(measuredSize(item.bytes, partial: item.partial))
                                .font(.system(size: 12, design: .rounded)).monospacedDigit().lineLimit(1)
                        } else { Image(systemName: icon).font(.system(size: 12)) }
                    }.padding(.horizontal, 5).foregroundStyle(.white)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .onHover { inside in if let entry = item.entry { hover(inside, entry.url) } }
            .accessibilityLabel(item.name + tr("，", ", ") + measuredSize(item.bytes, partial: item.partial))
            .accessibilityHint(item.entry?.isDirectory == false ? tr("在访达中显示", "Show in Finder") : tr("打开并查看内容", "Open to explore contents"))
            .help(item.name + " · " + measuredSize(item.bytes, partial: item.partial))
            .contextMenu {
                if let entry = item.entry { Button(tr("在访达中显示", "Show in Finder")) { reveal(entry.url) } }
            }
    }

    // Bisect the longer axis by byte weight, retaining an exact area before visual gutters.
    private static func layout(_ items: ArraySlice<MapItem>, in rect: CGRect) -> [MapCell] {
        guard let first = items.first else { return [] }
        guard items.count > 1 else { return [MapCell(item: first, rect: rect)] }
        let total = items.reduce(0.0) { $0 + Double($1.bytes) }
        var split = items.index(after: items.startIndex)
        var leading = Double(first.bytes)
        while split < items.index(before: items.endIndex) {
            let next = leading + Double(items[split].bytes)
            if abs(total / 2 - leading) <= abs(total / 2 - next) { break }
            leading = next
            items.formIndex(after: &split)
        }
        let horizontal = rect.width >= rect.height
        let length = horizontal ? rect.width : rect.height
        let (a, b) = rect.divided(atDistance: length * (leading / total), from: horizontal ? .minXEdge : .minYEdge)
        return layout(items[..<split], in: a) + layout(items[split...], in: b)
    }
}
