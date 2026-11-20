import SwiftUI
import AppKit

enum WorkspacePage: String, CaseIterable, Identifiable {
    case clean, software, optimize, analyze, system
    var id: Self { self }
    var title: String {
        switch self {
        case .clean: return tr("空间清理", "Clean")
        case .software: return tr("应用", "Apps")
        case .optimize: return tr("维护", "Maintain")
        case .analyze: return tr("磁盘分析", "Analyze")
        case .system: return tr("状态", "Status")
        }
    }
    var atmosphere: Color {
        switch self {
        case .clean: return Color(red: 0.133, green: 0.144, blue: 0.145)
        case .software, .optimize, .system: return Color(white: 0.144)
        case .analyze: return Color(red: 0.153, green: 0.144, blue: 0.133)
        }
    }

}

private enum AccessEntry: String, Identifiable {
    case settings, guide
    var id: Self { self }
}

private struct AccessGuideKey: FocusedValueKey {
    typealias Value = () -> Void
}

private extension FocusedValues {
    var accessGuide: (() -> Void)? {
        get { self[AccessGuideKey.self] }
        set { self[AccessGuideKey.self] = newValue }
    }
}

@main
struct StrataApp: App {
    @NSApplicationDelegateAdaptor(StrataAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Strata", id: "main") {
            WorkspaceView(workspace: appDelegate.workspace)
                .frame(minWidth: 790, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1000, height: 700)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            StrataCommands()
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceNavigation
    @Environment(\.openWindow) private var openWindow
    private var page: WorkspacePage { workspace.page }
    @AppStorage(AppLanguage.key) private var language: AppLanguage = .system
    @State private var accessEntry: AccessEntry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigation
    @StateObject private var cleanup = PreviewModel(kind: .clean)
    @StateObject private var maintenance = PreviewModel(kind: .optimize)
    @StateObject private var disk = DiskModel()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                navigationBar
                HStack(spacing: 8) {
                    languageMenu
                    Button { accessEntry = .settings } label: {
                        Label(tr("授权", "Access"), systemImage: "lock.open")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11).frame(height: 30)
                            .background(Capsule().fill(.white.opacity(0.055)))
                            .overlay(Capsule().strokeBorder(StrataColor.border))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(tr("在系统设置中管理 Strata 的访问权限", "Manage Strata’s access in System Settings"))
                    .accessibilityIdentifier("open-permissions")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 22)
            }
            .frame(maxWidth: .infinity).frame(height: 68)
            Group {
                switch page {
                case .clean:
                    CleanPage(model: cleanup) { location in
                        workspace.page = .analyze
                        disk.scan(location)
                    }
                case .software: SoftwarePage()
                case .optimize: MaintenancePage(model: maintenance)
                case .analyze: AnalyzePage(model: disk)
                case .system: SystemPage()
                }
            }.id(page).transition(.opacity).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.foregroundStyle(StrataColor.ink).tint(StrataColor.accent).background {
            LinearGradient(stops: [
                .init(color: page.atmosphere, location: 0),
                .init(color: StrataColor.paper, location: 0.68)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $accessEntry) { entry in
            PermissionsView(openSettingsOnAppear: entry == .settings)
                .environment(\.locale, language.locale)
        }
        .environment(\.locale, language.locale)
        .background(MainWindowReader { [openWindow] window in
            workspace.attach(window) { openWindow(id: "main") }
        })
        .focusedSceneValue(\.accessGuide, { accessEntry = .guide })
        .onDisappear { cleanup.cancel(); maintenance.cancel(); disk.cancel() }
    }

    private var languageMenu: some View {
        Menu {
            Picker(tr("语言", "Language"), selection: $language) {
                Text(tr("跟随系统", "System Default")).tag(AppLanguage.system)
                Text(verbatim: "简体中文").tag(AppLanguage.chinese)
                Text(verbatim: "English").tag(AppLanguage.english)
            }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe").font(.system(size: 14, weight: .medium))
                Text(verbatim: language.resolved == .chinese ? "中文" : "EN")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 7).frame(height: 32).contentShape(Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tint(StrataColor.muted)
        .help("简体中文 / English")
        .accessibilityLabel(tr("界面语言", "Interface language"))
        .accessibilityIdentifier("language-menu")
    }

    private var navigationBar: some View {
        HStack(spacing: 2) {
            Relief(miniature: true)
                .frame(width: 25, height: 25)
                .padding(.leading, 7).padding(.trailing, 4)
                .accessibilityHidden(true).help("Strata")
            ForEach(Array(WorkspacePage.allCases.enumerated()), id: \.element) { index, section in
                let selected = section == page
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { workspace.page = section }
                } label: {
                    Text(section.title)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 38).padding(.horizontal, 12).frame(height: 31)
                        .foregroundStyle(selected ? Color.black.opacity(0.84) : StrataColor.ink.opacity(0.86))
                        .overlay(alignment: .topTrailing) {
                            if !selected && hasWork(section) {
                                Circle().fill(StrataColor.mint).frame(width: 4, height: 4)
                                    .padding([.top, .trailing], 5).accessibilityLabel(tr("运行中", "Running"))
                            }
                        }
                        .background {
                            if selected {
                                Capsule().fill(Color(white: 0.94))
                                    .matchedGeometryEffect(id: "currentPage", in: navigation)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .help(section.title + "  ⌘" + String(index + 1))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .modifier(NavigationGlass())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("主导航", "Main navigation"))
        .accessibilityIdentifier("workspace-navigation")
    }

    private func hasWork(_ page: WorkspacePage) -> Bool {
        switch page {
        case .clean: return cleanup.running
        case .optimize: return maintenance.running
        case .analyze: return disk.running
        default: return false
        }
    }
}

private struct StrataCommands: Commands {
    @FocusedValue(\.accessGuide) private var accessGuide
    @AppStorage(AppLanguage.key) private var language: AppLanguage = .system

    var body: some Commands {
        let _ = language
        CommandGroup(after: .appInfo) {
            Button(tr("权限设置…", "Access Settings…")) { accessGuide?() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(accessGuide == nil)
        }
    }
}

private struct NavigationGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(StrataColor.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(StrataColor.border))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        }
    }
}
