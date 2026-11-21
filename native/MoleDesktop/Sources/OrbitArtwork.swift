import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// The globe stays fixed while the tracker and scan latitude move over it.
struct OrbitArtwork: View {
    var isScanning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private static let earth: CGImage? = {
        guard let url = Bundle.main.url(forResource: "Earth", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    var body: some View {
        GeometryReader { geometry in
            let orbit = OrbitProjection(size: geometry.size)
            ZStack {
                Canvas { context, _ in
                    context.stroke(orbit.track(), with: .color(.cyan.opacity(0.28)), lineWidth: 0.8)
                    context.stroke(orbit.track(scale: 1.10), with: .color(.white.opacity(0.18)),
                                   style: StrokeStyle(lineWidth: 0.65, dash: [1, 5]))
                }
                if let earth = Self.earth {
                    Image(decorative: earth, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: orbit.diameter, height: orbit.diameter)
                        .shadow(color: .cyan.opacity(0.14), radius: orbit.diameter * 0.035)
                }
                Canvas { context, _ in
                    context.stroke(orbit.track(through: .pi), with: .color(.white.opacity(0.33)), lineWidth: 0.8)
                }
                if reduceMotion || scenePhase != .active {
                    overlay(orbit, elapsed: 0)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { frame in
                        overlay(orbit, elapsed: frame.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func overlay(_ orbit: OrbitProjection, elapsed: TimeInterval) -> some View {
        Canvas { context, _ in
            let cycle = elapsed.truncatingRemainder(dividingBy: 55) / 55
            let angle = 0.45 + 2 * .pi * cycle
            let position = orbit.position(angle)
            // Fade the tracker behind the Earth's limb as it enters the far half.
            let offset = hypot(position.x - orbit.center.x, position.y - orbit.center.y)
            let visibility = sin(angle) >= 0 ? 1 : min(1, max(0, (offset - orbit.limbRadius) / 4))
            if visibility > 0 {
                let mint = Color(red: 0.72, green: 0.99, blue: 0.89)
                for (radius, opacity) in [(6.0, 0.12), (3.6, 0.26), (1.9, 1.0)] {
                    let dot = CGRect(x: position.x - radius, y: position.y - radius,
                                     width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: dot), with: .color(mint.opacity(opacity * visibility)))
                }
            }
            if isScanning {
                let progress = (elapsed + 3).truncatingRemainder(dividingBy: 7) / 7
                let latitude = (progress - 0.5) * .pi
                let stroke = Color(red: 0.60, green: 1, blue: 0.85)
                for (width, opacity) in [(8.0, 0.08), (3.5, 0.22), (1.2, 0.92)] {
                    context.stroke(orbit.scanLine(latitude: latitude), with: .color(stroke.opacity(opacity)), lineWidth: width)
                }
            }
        }
    }
}

private struct OrbitProjection {
    let center: CGPoint
    let diameter: CGFloat
    let major: CGFloat
    private let tilt = -0.31
    // The opaque Earth spans 96% of the square PNG; the rest includes its atmosphere.
    var limbRadius: CGFloat { diameter * 0.48 }

    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        diameter = min(size.width * 0.66, size.height * 0.86)
        major = min(size.width * 0.46, size.height * 0.83)
    }

    func position(_ angle: Double) -> CGPoint {
        let x = major * cos(angle), y = major * 0.255 * sin(angle)
        return CGPoint(x: center.x + x * cos(tilt) - y * sin(tilt),
                       y: center.y + x * sin(tilt) + y * cos(tilt))
    }

    func track(through angle: Double = 2 * .pi, scale: Double = 1) -> Path {
        let axis = major * scale
        let transform = CGAffineTransform(a: axis * cos(tilt), b: axis * sin(tilt),
                                          c: -axis * 0.255 * sin(tilt), d: axis * 0.255 * cos(tilt),
                                          tx: center.x, ty: center.y)
        var path = Path()
        path.addRelativeArc(center: .zero, radius: 1, startAngle: .zero, delta: .radians(angle), transform: transform)
        return path
    }

    // Project a latitude circle onto the visible hemisphere of the raster globe.
    func scanLine(latitude: Double) -> Path {
        let inclination = 18 * Double.pi / 180
        let sinLat = sin(latitude), cosLat = cos(latitude)
        let radius = limbRadius
        let roll = -0.12
        var path = Path()
        var visible = false
        for index in 0...96 {
            let lon = Double(index) * 2 * .pi / 96 - .pi
            let z = sinLat * sin(inclination) + cosLat * cos(lon) * cos(inclination)
            if z < 0 { visible = false; continue }
            let x = cosLat * sin(lon)
            let y = sinLat * cos(inclination) - cosLat * cos(lon) * sin(inclination)
            let point = CGPoint(x: center.x + radius * (x * cos(roll) + y * sin(roll)),
                                y: center.y - radius * (-x * sin(roll) + y * cos(roll)))
            if visible { path.addLine(to: point) } else { path.move(to: point) }
            visible = true
        }
        return path
    }
}
