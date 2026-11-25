import AppKit

private final class Wheel: NSEvent {
    var y = 0.0
    var x = 0.0
    var precise = false
    var inverted = false
    var gesture: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    var time = 1.0
    var point = NSPoint(x: 55, y: 20)
    weak var targetWindow: NSWindow?
    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaY: CGFloat { y }
    override var scrollingDeltaX: CGFloat { x }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var isDirectionInvertedFromDevice: Bool { inverted }
    override var phase: NSEvent.Phase { gesture }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var timestamp: TimeInterval { time }
    override var locationInWindow: NSPoint { point }
    override var window: NSWindow? { targetWindow }
}

@main enum VolumeWheelTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 50),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let target = VolumeWheelTarget.Target(frame: NSRect(x: 40, y: 10, width: 78, height: 20))
        window.contentView!.addSubview(target)
        let e = Wheel()
        e.targetWindow = window
        var sent: [Double] = []
        target.change = { sent.append($0) }
        target.volume = 0.5

        // The actual wheel target must leave clicks, other windows and the rest of the row alone.
        e.y = 8
        precondition(target.hitTest(e.point) == nil)
        e.point.x = 145
        precondition(!target.consume(e))
        e.point.x = 55
        e.targetWindow = nil
        precondition(!target.consume(e))
        e.targetWindow = window
        for _ in 0..<3 { precondition(target.consume(e)) }
        precondition(sent == [0.51, 0.52, 0.53]) // Accelerated detents and a delayed mixer reply.
        e.inverted = true
        precondition(target.consume(e) && sent.last == 0.52)

        sent.removeAll()
        e.time += 2
        target.volume = 0.20 // After a break, adopt volume changes from the device.
        e.precise = true
        e.inverted = false
        e.gesture = .began
        e.y = 0
        _ = target.consume(e)
        e.gesture = .changed
        e.y = 1
        for _ in 0..<20 { precondition(target.consume(e)) }
        precondition(sent == [0.21, 0.22]) // Sub-percent deltas accumulate.
        e.y = 100
        e.momentum = .changed
        precondition(target.consume(e) && sent == [0.21, 0.22])
        e.momentum = []
        e.x = 30
        e.y = 1
        e.gesture = .began
        precondition(!target.consume(e))
        e.x = 0
        e.gesture = .changed
        precondition(!target.consume(e)) // Keep horizontal gestures with the panel.

        e.time += 2
        e.gesture = []
        e.precise = false
        e.y = 1
        target.volume = 0.99
        for _ in 0..<4 { precondition(target.consume(e)) }
        precondition(sent == [0.21, 0.22, 1])
        e.time += 2
        target.volume = 0.01
        e.y = -1
        for _ in 0..<4 { precondition(target.consume(e)) }
        precondition(sent == [0.21, 0.22, 1, 0])
        print("PASS slider wheel hit area, damping, asynchronous volume, direction, momentum and limits")
    }
}
