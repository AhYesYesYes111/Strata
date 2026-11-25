import AppKit
import SwiftUI

@MainActor
final class WorkspaceNavigation: ObservableObject {
    @Published var page: WorkspacePage = .clean
    private weak var window: NSWindow?
    private var reopen: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    func attach(_ window: NSWindow, reopen: @escaping () -> Void) {
        self.reopen = reopen
        guard window !== self.window else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil }
        }
    }

    func showStatus() {
        page = .system
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            reopen?()
        }
    }
}

struct MainWindowReader: NSViewRepresentable {
    let attach: (NSWindow) -> Void

    final class Reader: NSView {
        var attach: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach?(window) }
        }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.attach = attach
        return view
    }
    func updateNSView(_ view: Reader, context: Context) { view.attach = attach }
}

@MainActor
final class StrataAppDelegate: NSObject, NSApplicationDelegate {
    let workspace = WorkspaceNavigation()
    private var menuBar: StrataMenuBar?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = StrataMenuBar(onOpenStatus: workspace.showStatus)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
final class StrataMenuBar: NSObject, NSPopoverDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    private let onOpenStatus: () -> Void

    init(onOpenStatus: @escaping () -> Void) {
        self.onOpenStatus = onOpenStatus
        super.init()
        let size = NSSize(width: 20, height: 20)
        let icon = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            ContourMark.draw(in: context, rect: CGRect(origin: .zero, size: size), template: true)
            return true
        }
        icon.isTemplate = true
        if let button = item.button {
            button.image = icon
            button.toolTip = "Strata"
            button.setAccessibilityLabel("Strata")
            button.target = self
            button.action = #selector(toggle)
        }
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let screenHeight = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 780
        let view = MenuPopoverView(maximumHeight: max(180, screenHeight - 24)) { [weak self] in
            self?.popover.performClose(nil)
            self?.onOpenStatus()
        }
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverWillShow(_ notification: Notification) {
        MonitorSession.shared.startMenu()
        item.button?.highlight(true)
    }

    func popoverDidClose(_ notification: Notification) {
        MonitorSession.shared.stopMenu()
        item.button?.highlight(false)
        popover.contentViewController = nil
    }
}

private struct MenuContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MenuPopoverView: View {
    let maximumHeight: CGFloat
    let onOpenStatus: () -> Void
    @ObservedObject private var monitor = MonitorSession.shared
    @AppStorage(AppLanguage.key) private var language: AppLanguage = .system
    @State private var contentHeight: CGFloat = 740

    var body: some View {
        ScrollView {
            MenuDashboard(readings: monitor.readings, processes: monitor.processes,
                          onOpenStatus: onOpenStatus, onQuit: { NSApp.terminate(nil) })
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MenuContentHeight.self, value: geometry.size.height)
                })
        }
        .frame(width: 352, height: min(contentHeight, maximumHeight))
        .onPreferenceChange(MenuContentHeight.self) { if $0 > 0 { contentHeight = ceil($0) } }
        .background(LinearGradient(colors: [StrataColor.rail, StrataColor.paper],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.locale, language.locale)
        .preferredColorScheme(.dark)
    }
}
