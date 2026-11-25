import SwiftUI

struct ContourArtwork: ViewModifier {
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var cache = GeometryCache()
    @State private var contact: ContourGeometry.Contact?
    @State private var ringing: [Int: Release] = [:]

    private struct Release {
        let contact: ContourGeometry.Contact
        let date: Date
    }

    // Per-window memoization. Hover and animation updates reuse the same paths.
    private final class GeometryCache {
        private var value: ContourGeometry?

        func geometry(in rect: CGRect) -> ContourGeometry {
            if let value, value.rect == rect { return value }
            let geometry = ContourGeometry(rect: rect)
            value = geometry
            return geometry
        }
    }

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let rect = CGRect(x: size.width * 0.42, y: -size.height * 0.20, width: size.width * 0.96, height: size.height * 0.92)
            let contours = enabled ? cache.geometry(in: rect) : nil
            let interactive = enabled && !reduceMotion && scenePhase == .active
            content.frame(width: size.width, height: size.height)
                .background {
                    if let contours { terrain(contours, interactive: interactive) }
                }
                .onContinuousHover { phase in
                    guard interactive else { return }
                    let next: ContourGeometry.Contact?
                    if case .active(let point) = phase { next = contours?.nearest(to: point) } else { next = nil }
                    guard contact != next else { return }
                    if let contact, contact.line != next?.line {
                        ringing[contact.line] = Release(contact: contact, date: Date())
                    }
                    if let next, ringing[next.line] != nil { ringing.removeValue(forKey: next.line) }
                    contact = next
                }
                .task(id: ringing.values.map(\.date).max()) {
                    guard !ringing.isEmpty else { return }
                    do { try await Task.sleep(nanoseconds: 850_000_000) } catch { return }
                    ringing.removeAll()
                }
                .onChange(of: interactive) { enabled in
                    if !enabled { contact = nil; ringing.removeAll() }
                }
        }
    }

    private func terrain(_ contours: ContourGeometry, interactive: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: ringing.isEmpty || !interactive)) { frame in
            Canvas { context, _ in
                for (index, line) in contours.lines.enumerated() {
                    var pulls: [(ContourGeometry.Contact, Double)] = []
                    if interactive {
                        if let contact, abs(index - contact.line) <= 1 { pulls.append((contact, 1)) }
                        for release in ringing.values where abs(index - release.contact.line) <= 1 {
                            let elapsed = max(0, frame.date.timeIntervalSince(release.date))
                            pulls.append((release.contact, exp(-6 * elapsed) * cos(21 * elapsed)))
                        }
                    }
                    let path = pulls.isEmpty ? line.restingPath : line.displacedPath { angle in
                        pulls.reduce(0) { sum, pulse in
                            let (hit, gain) = pulse
                            let distance = 1 - cos(angle - hit.angle)
                            return sum + gain * hit.pull * exp(-13 * distance) * (index == hit.line ? 1 : 0.22)
                        }
                    }
                    let major = index.isMultiple(of: 3)
                    context.stroke(path, with: .color(.white.opacity(major ? 0.65 : 0.38)),
                                   style: StrokeStyle(lineWidth: major ? 1.3 : 0.8, lineJoin: .round))
                }
            }
        }
        .mask {
            LinearGradient(stops: [.init(color: .white.opacity(0.30), location: 0.2),
                                   .init(color: .white, location: 0.85)],
                           startPoint: .leading, endPoint: .trailing)
                .mask(LinearGradient(stops: [.init(color: .white, location: 0.42),
                                             .init(color: .white.opacity(0.40), location: 0.76)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

// Geometry is shared by rendering and hit testing. Each bounding box covers
// consecutive segments, including their closing endpoint and the hover radius.
struct ContourGeometry {
    struct Contact: Equatable {
        let line: Int
        let angle: Double
        let pull: Double
    }

    private static let radius: CGFloat = 10
    private static let angles = ContourMark.angles
    private static let directions = angles.map { CGVector(dx: cos($0), dy: sin($0)) }
    private static let unitLines = (0..<34).map { index in
        angles.map { ContourMark.point(angle: $0, level: 0.02 + 0.11 * Double(index),
                                       in: CGRect(x: 0, y: 0, width: 1, height: 1)) }
    }

    struct Line {
        let points: [CGPoint]
        let restingPath: Path
        let chunks: [(segments: Range<Int>, bounds: CGRect)]

        init(points: [CGPoint]) {
            self.points = points
            restingPath = Path { path in
                path.addLines(points)
                path.closeSubpath()
            }
            chunks = stride(from: 0, to: points.count, by: 10).map { first in
                let end = min(first + 10, points.count)
                var box = CGRect.null
                for i in first...end {
                    box = box.union(CGRect(origin: points[i % points.count], size: .zero))
                }
                return (first..<end, box.insetBy(dx: -radius, dy: -radius))
            }
        }

        func displacedPath(offset: (Double) -> Double) -> Path {
            Path { path in
                for (i, base) in points.enumerated() {
                    let amount = offset(angles[i])
                    let point = CGPoint(x: base.x + directions[i].dx * amount, y: base.y + directions[i].dy * amount)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
            }
        }
    }

    let rect: CGRect
    let lines: [Line]

    init(rect: CGRect) {
        self.rect = rect
        lines = Self.unitLines.map { points in
            Line(points: points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
        }
    }

    func nearest(to cursor: CGPoint) -> Contact? {
        var best: Contact?
        var closestSquared = Self.radius * Self.radius
        for (index, line) in lines.enumerated() {
            let points = line.points
            for chunk in line.chunks where chunk.bounds.contains(cursor) {
                for i in chunk.segments {
                    let start = points[i], end = points[(i + 1) % points.count]
                    let width = end.x - start.x, height = end.y - start.y
                    let fromX = cursor.x - start.x, fromY = cursor.y - start.y
                    let along = min(1, max(0, (fromX * width + fromY * height) / max(0.001, width * width + height * height)))
                    let deltaX = fromX - along * width, deltaY = fromY - along * height
                    let squared = deltaX * deltaX + deltaY * deltaY
                    if squared < closestSquared {
                        closestSquared = squared
                        let angle = 2 * Double.pi * (Double(i) + along) / Double(points.count)
                        best = Contact(line: index, angle: angle, pull: deltaX * cos(angle) + deltaY * sin(angle))
                    }
                }
            }
        }
        return best
    }
}
