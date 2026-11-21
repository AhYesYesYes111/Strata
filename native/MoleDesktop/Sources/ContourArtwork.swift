import SwiftUI

struct ContourArtwork: ViewModifier {
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var contact: Contact?
    @State private var ringing: [Int: Release] = [:]

    private struct Release {
        let contact: Contact
        let date: Date
    }

    private struct Contact {
        let line: Int
        let angle: Double
        let pull: Double
    }

    private static let levels = (0..<34).map { 0.02 + 0.11 * Double($0) }
    private static let samples = levels.map { level in
        (0..<120).map { index in
            ContourMark.point(angle: 2 * .pi * Double(index) / 120, level: level, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let rect = CGRect(x: size.width * 0.42, y: -size.height * 0.20, width: size.width * 0.96, height: size.height * 0.92)
            let interactive = enabled && !reduceMotion && scenePhase == .active
            content.frame(width: size.width, height: size.height)
                .background {
                    if enabled { terrain(rect: rect, interactive: interactive) }
                }
                .onContinuousHover { phase in
                    guard interactive else { return }
                    let next: Contact?
                    if case .active(let point) = phase { next = nearest(to: point, in: rect) } else { next = nil }
                    if let contact, contact.line != next?.line {
                        ringing[contact.line] = Release(contact: contact, date: Date())
                    }
                    if let next { ringing.removeValue(forKey: next.line) }
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

    private func terrain(rect: CGRect, interactive: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: ringing.isEmpty || !interactive)) { frame in
                Canvas { context, _ in
                    for (index, level) in Self.levels.enumerated() {
                        var pulls: [(Contact, Double)] = []
                        if interactive {
                            if let contact, abs(index - contact.line) <= 1 { pulls.append((contact, 1)) }
                            for release in ringing.values where abs(index - release.contact.line) <= 1 {
                                let elapsed = max(0, frame.date.timeIntervalSince(release.date))
                                pulls.append((release.contact, exp(-6 * elapsed) * cos(21 * elapsed)))
                            }
                        }
                        let path = ContourMark.path(level: level, in: rect) { angle in
                            pulls.reduce(0) { sum, pulse in
                                let (hit, gain) = pulse
                                let distance = 1 - cos(angle - hit.angle)
                                return sum + gain * hit.pull * exp(-13 * distance) * (index == hit.line ? 1 : 0.22)
                            }
                        }
                        let major = index.isMultiple(of: 3)
                        context.stroke(Path(path), with: .color(.white.opacity(major ? 0.65 : 0.38)),
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

    private func nearest(to cursor: CGPoint, in rect: CGRect) -> Contact? {
        var best: Contact?
        var closestSquared = 100.0
        for (index, points) in Self.samples.enumerated() {
            for sample in points.indices {
                let start = points[sample], end = points[(sample + 1) % points.count]
                let width = (end.x - start.x) * rect.width, height = (end.y - start.y) * rect.height
                let fromX = cursor.x - (rect.minX + start.x * rect.width)
                let fromY = cursor.y - (rect.minY + start.y * rect.height)
                let along = min(1, max(0, (fromX * width + fromY * height) / max(0.001, width * width + height * height)))
                let deltaX = fromX - along * width, deltaY = fromY - along * height
                let squared = deltaX * deltaX + deltaY * deltaY
                if squared < closestSquared {
                    closestSquared = squared
                    let angle = 2 * Double.pi * (Double(sample) + along) / Double(points.count)
                    best = Contact(line: index, angle: angle, pull: deltaX * cos(angle) + deltaY * sin(angle))
                }
            }
        }
        return best
    }
}
