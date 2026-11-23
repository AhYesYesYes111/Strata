import AppKit
import SwiftUI

private enum ApplicationLocation: CaseIterable, Identifiable {
    case shared, system, personal

    var title: String {
        switch self {
        case .shared: return tr("应用程序", "Applications")
        case .system: return tr("系统应用", "System apps")
        case .personal: return tr("个人应用", "User apps")
        }
    }

    var id: Self { self }

    var folder: URL {
        switch self {
        case .system: return URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        case .shared: return URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .personal: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        }
    }
}

private struct InstalledApplication: Identifiable {
    let url: URL
    let name: String
    let version: String?
    let location: ApplicationLocation
    var id: URL { url }
}

private enum ApplicationSize {
    case measured(Int64), unavailable

    var text: String {
        switch self {
        case .measured(let bytes): return storageSize(bytes)
        case .unavailable: return "—"
        }
    }
}

private struct AppInventory {
    var apps: [InstalledApplication] = []
    var partial = false

    static func scan() async throws -> Self {
        var inventory = AppInventory()
        let fm = FileManager.default
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        for location in ApplicationLocation.allCases {
            let folder = location.folder
            if location == .personal && !fm.fileExists(atPath: folder.path) { continue }
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, _ in
                inventory.partial = true
                return true
            }) else {
                inventory.partial = true
                continue
            }
            while let url = walker.nextObject() as? URL {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    inventory.partial = true
                    break
                }
                guard let values = try? url.resourceValues(forKeys: keys) else {
                    walker.skipDescendants()
                    inventory.partial = true
                    continue
                }
                if values.isSymbolicLink == true {
                    walker.skipDescendants()
                    continue
                }
                guard values.isDirectory == true else { continue }
                if url.pathExtension.lowercased() == "app" {
                    walker.skipDescendants()
                    let appBundle = Bundle(url: url)
                    let name = appBundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? appBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? url.deletingPathExtension().lastPathComponent
                    let version = appBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    inventory.apps.append(InstalledApplication(url: url, name: name, version: version, location: location))
                } else if values.isPackage == true {
                    walker.skipDescendants()
                }
            }
        }
        inventory.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return inventory
    }
}

struct SoftwarePage: View {
    @Environment(\.locale) private var locale
    @State private var inventory: AppInventory?
    @State private var sizes: [URL: ApplicationSize] = [:]
    @State private var search = ""
    @State private var location: ApplicationLocation?
    @State private var generation = 0

    private var matches: [InstalledApplication] {
        (inventory?.apps ?? []).filter { app in
            (location == nil || location == app.location) && (search.isEmpty || app.name.localizedStandardContains(search) || app.url.lastPathComponent.localizedStandardContains(search))
        }
    }

    var body: some View {
        let _ = locale
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(tr("应用软件", "Applications"), detail: tr("查看本机应用、版本和安装位置。", "Browse installed apps, versions, and locations."))
                HStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(StrataColor.muted)
                        TextField(tr("搜索应用", "Search apps"), text: $search).textFieldStyle(.plain)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel(tr("清除搜索", "Clear search"))
                        }
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(StrataColor.panel, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(StrataColor.border))
                    Picker(tr("位置", "Location"), selection: $location) {
                        Text(tr("全部位置", "All locations")).tag(nil as ApplicationLocation?)
                        ForEach(ApplicationLocation.allCases) { place in Text(place.title).tag(Optional(place)) }
                    }.labelsHidden().fixedSize()
                    Button { generation += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .help(tr("重新读取应用列表", "Refresh apps")).accessibilityLabel(tr("重新读取应用列表", "Refresh apps"))
                }
                if let inventory {
                    let visible = matches
                    HStack {
                        Text(tr("\(visible.count) 个应用", visible.count == 1 ? "1 app" : "\(visible.count) apps")).font(.headline)
                        Spacer()
                        if inventory.partial { Text(tr("仅显示已读取的应用", "Some locations could not be read")).font(.caption).foregroundStyle(StrataColor.muted) }
                    }
                    if visible.isEmpty {
                        Panel { Text(search.isEmpty ? tr("此位置没有可显示的应用。", "No apps in this location.") : tr("没有找到匹配的应用。", "No matching apps.")).foregroundStyle(StrataColor.muted).frame(maxWidth: .infinity) }
                    } else {
                        LazyVStack(spacing: 0) {
                            HStack(spacing: 14) {
                                Text(tr("名称", "Name"))
                                Spacer()
                                Text(tr("版本", "Version")).frame(width: 100, alignment: .leading)
                                Text(tr("大小", "Size")).frame(width: 78, alignment: .trailing)
                                Color.clear.frame(width: 22, height: 1)
                            }
                            .font(.caption.weight(.medium)).foregroundStyle(StrataColor.muted)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(.white.opacity(0.025))
                            ForEach(visible) { app in
                                HStack(spacing: 14) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                        .resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name).font(.system(size: 14, weight: .medium)).lineLimit(1).foregroundStyle(StrataColor.ink)
                                        Text(app.url.path).font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(StrataColor.muted)
                                    }
                                    Spacer(minLength: 8)
                                    Text(verbatim: app.version ?? "—").font(.caption.monospacedDigit())
                                        .lineLimit(1).truncationMode(.middle).foregroundStyle(StrataColor.muted)
                                        .frame(width: 100, alignment: .leading)
                                    Text(verbatim: sizes[app.url]?.text ?? "…")
                                        .font(.caption.monospacedDigit()).foregroundStyle(StrataColor.muted)
                                        .frame(width: 78, alignment: .trailing)
                                        .help(tr("应用包占用的磁盘空间", "Disk space used by the app bundle"))
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([app.url])
                                    } label: { Image(systemName: "folder").frame(width: 22, height: 22) }
                                    .buttonStyle(.borderless).help(tr("在访达中显示", "Show in Finder")).accessibilityLabel(tr("在访达中显示 \(app.name)", "Show \(app.name) in Finder"))
                                }
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                if app.id != visible.last?.id { Divider().padding(.leading, 66) }
                            }
                        }
                        .background(StrataColor.panel).clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StrataColor.border))
                    }
                } else {
                    ProgressView(tr("正在读取应用…", "Reading apps…")).frame(maxWidth: .infinity).padding()
                }
            }.padding(.horizontal, 26).padding(.vertical, 21)
        }
        .task(id: generation) {
            inventory = nil
            sizes = [:]
            guard let result = try? await AppInventory.scan(), !Task.isCancelled else { return }
            inventory = result
            await withTaskGroup(of: (URL, Int64?).self) { group in
                var apps = result.apps.makeIterator()
                func enqueueNext() {
                    guard let url = apps.next()?.url else { return }
                    _ = group.addTaskUnlessCancelled { (url, try? await DiskScanner.allocatedDirectorySize(url)) }
                }
                for _ in 0..<3 { enqueueNext() }
                for await (url, bytes) in group {
                    guard !Task.isCancelled else { return }
                    sizes[url] = bytes.map(ApplicationSize.measured) ?? .unavailable
                    enqueueNext()
                }
            }
        }
    }
}
