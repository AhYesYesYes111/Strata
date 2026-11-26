import AppKit
import SwiftUI

@main struct MenuViewportTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let menu = MenuDashboard(readings: StatusReadings(), dismissMenu: {}, onOpenStatus: {}, onQuit: {})
        let natural = NSHostingController(rootView: menu).view.fittingSize
        let limit = natural.height + 100

        // Use the same controller for expansion, overflow and collapse.
        func viewport(extra: CGFloat) -> some View {
            MenuViewport(maximumHeight: limit, resize: { _ in }) {
                VStack(spacing: 0) {
                    menu
                    Color.clear.frame(height: extra)
                }
            }
        }
        let controller = NSHostingController(rootView: viewport(extra: 0))
        for extra in [CGFloat(0), 50, 400, 30, 0] {
            controller.rootView = viewport(extra: extra)
            let size = controller.sizeThatFits(in: CGSize(width: 352, height: limit))
            precondition(size.width == 352)
            precondition(abs(size.height - min(natural.height + extra, limit)) <= 1)
        }
        print("Passed menu content fitting, height limit, expansion and collapse.")
    }
}
