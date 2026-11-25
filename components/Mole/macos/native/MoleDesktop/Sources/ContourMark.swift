import CoreGraphics
import Foundation

enum ContourMark {
    static func point(angle: Double, level: Double, in rect: CGRect) -> CGPoint {
        let shape = min(1, level)
        let ridge = 1 + 0.13 * sin(3 * angle + 0.7 + 0.5 * shape) + 0.055 * cos(5 * angle - shape)
        let scale = (0.15 + 0.76 * level) * ridge
        return CGPoint(x: rect.midX + rect.width * (0.46 * scale * cos(angle) - 0.10 * (1 - shape)),
                       y: rect.midY + rect.height * (0.43 * scale * sin(angle) + 0.08 * (1 - shape) - 0.11 * scale * cos(angle)))
    }

    static func path(level: Double, in rect: CGRect, offset: (Double) -> Double = { _ in 0 }) -> CGPath {
        let path = CGMutablePath()
        for sample in 0..<120 {
            let angle = 2 * Double.pi * Double(sample) / 120
            var vertex = point(angle: angle, level: level, in: rect)
            let displacement = offset(angle)
            vertex.x += cos(angle) * displacement
            vertex.y += sin(angle) * displacement
            if sample == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
        }
        path.closeSubpath()
        return path
    }

    static func draw(in context: CGContext, rect: CGRect, template: Bool = false) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineJoin(.round)
        context.setLineWidth(min(rect.width, rect.height) * 0.058)
        context.setStrokeColor(CGColor(gray: template ? 0 : 0.96, alpha: 1))
        for level in [0.13, 0.54, 0.96] {
            context.addPath(path(level: level, in: rect))
            context.strokePath()
        }
    }
}
