import AppKit
import SwiftUI

/// Preserve sub-percent motion between events. The mixer returns volume
/// snapshots asynchronously, while the slider sends whole percentage changes.
struct VolumeWheelInput {
    private var position = 0.0
    private var lastEvent: TimeInterval?
    private enum Destination { case panel, undecided, slider }
    private var destination = Destination.panel

    /// Returns true for events belonging to this slider, including its momentum tail.
    mutating func handle(_ event: NSEvent, volume: Double, change: (Double) -> Void) -> Bool {
        if !event.momentumPhase.isEmpty { return destination == .slider }
        let phase = event.phase
        if phase.contains(.ended) || phase.contains(.cancelled) { return destination == .slider }
        if phase.isEmpty || phase.contains(.mayBegin) || phase.contains(.began) {
            destination = .undecided
        }
        if destination == .undecided && (event.scrollingDeltaY != 0 || event.scrollingDeltaX != 0) {
            destination = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? .slider : .panel
        }
        guard destination == .slider else { return false }

        if event.timestamp - (lastEvent ?? -.infinity) > 0.45 {
            position = volume
        }
        lastEvent = event.timestamp
        let before = (position * 100).rounded()
        // 1% per physical detent, or per 10 points of deliberate trackpad travel.
        ScrollWheelStep.apply(event: event, value: &position, sensitivity: 0.001, in: 0...1)
        let after = (position * 100).rounded()
        if before != after { change(after / 100) }
        return true
    }
}

/// Leave the SwiftUI slider in charge of clicks, drags, keyboard and accessibility.
/// Intercept scrolls before the enclosing ScrollView consumes them.
struct VolumeWheelTarget: NSViewRepresentable {
    let hovered: Bool
    let volume: Double
    let change: (Double) -> Void

    func makeNSView(context: Context) -> Target { Target() }

    func updateNSView(_ target: Target, context: Context) {
        target.volume = volume
        target.change = change
        if hovered { target.listen() } else { target.stop() }
    }

    static func dismantleNSView(_ target: Target, coordinator: ()) { target.stop() }

    final class Target: NSView {
        var volume = 0.0
        var change: ((Double) -> Void)?
        private var monitor: Any?
        private var input = VolumeWheelInput()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func listen() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.consume(event) == true ? nil : event
            }
        }

        func consume(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, let change else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), visibleRect.contains(point) else { return false }
            return input.handle(event, volume: volume, change: change)
        }

        func stop() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            input = VolumeWheelInput()
        }
    }
}
