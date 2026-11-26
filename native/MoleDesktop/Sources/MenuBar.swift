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
        FineTuneConnection.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) { FineTuneConnection.shared.stop() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// A menu-bar control can take keyboard input while the user's app keeps its menu bar.
@MainActor
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class StrataMenuBar: NSObject, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
    private let onOpenStatus: () -> Void
    private var externalClickMonitor: Any?
    private var localClickMonitor: Any?

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
        panel.delegate = self
        panel.title = "Strata"
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
    }

    @objc private func toggle() {
        if panel.isVisible {
            panel.close()
            return
        }
        guard let screen = item.button?.window?.screen else { return }
        let view = MenuPopoverView(maximumHeight: max(180, screen.visibleFrame.height - 24), resize: { [weak self] size in
            self?.positionPanel(contentSize: size)
        }, dismissMenu: { [weak self] in
            self?.panel.close()
        }, onOpenStatus: onOpenStatus)
        let controller = NSHostingController(rootView: view)
        let size = controller.view.fittingSize
        panel.contentViewController = controller
        positionPanel(contentSize: size)
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        MonitorSession.shared.startMenu()
        FineTuneConnection.shared.setMenuVisible(true)
        observeDismissal()
    }

    private var buttonFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func positionPanel(contentSize: NSSize) {
        guard contentSize.width > 0, contentSize.height > 0,
              let anchor = buttonFrame, let screen = item.button?.window?.screen else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: ceil(contentSize.width), height: ceil(contentSize.height))
        let x = min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = max(visible.minY, min(anchor.minY, visible.maxY) - 4 - size.height)
        let frame = NSRect(origin: NSPoint(x: floor(x), y: floor(y)), size: size)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    private func observeDismissal() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        externalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self else { return }
            // The system menu bar can forward this same click to the button's
            // toggle action. Let that action close the panel exactly once.
            if event.type == .leftMouseDown, self.buttonFrame?.contains(NSEvent.mouseLocation) == true { return }
            self.panel.close()
        }
        // Strata's own workspace window can receive the click while a native
        // picker menu or the status button should be free to finish tracking.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            if let self, event.window !== self.item.button?.window, event.window?.canBecomeMain == true {
                self.panel.close()
            }
            return event
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let externalClickMonitor { NSEvent.removeMonitor(externalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        externalClickMonitor = nil
        localClickMonitor = nil
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
        MonitorSession.shared.stopMenu()
        FineTuneConnection.shared.setMenuVisible(false)
        item.button?.highlight(false)
        panel.contentViewController = nil
    }

    @objc private func frontmostApplicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        panel.close()
    }
}

private struct MenuPopoverView: View {
    let maximumHeight: CGFloat
    let resize: (CGSize) -> Void
    let dismissMenu: () -> Void
    let onOpenStatus: () -> Void
    @ObservedObject private var monitor = MonitorSession.shared
    @AppStorage(AppLanguage.key) private var language: AppLanguage = .system

    var body: some View {
        MenuViewport(maximumHeight: maximumHeight, resize: resize) {
            MenuDashboard(readings: monitor.readings, dismissMenu: dismissMenu,
                          onOpenStatus: { dismissMenu(); onOpenStatus() }, onQuit: { NSApp.terminate(nil) })
        }
        .background(LinearGradient(colors: [StrataColor.rail, StrataColor.paper],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .environment(\.locale, language.locale)
        .preferredColorScheme(.dark)
    }
}
