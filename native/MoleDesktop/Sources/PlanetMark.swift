import CoreGraphics
import Foundation

/// The same silhouette is drawn in the Dock, the navigation bar and the menu bar.
enum PlanetMark {
    static func draw(in context: CGContext, rect: CGRect, template: Bool = false) {
        context.saveGState()
        defer { context.restoreGState() }
        let edge = min(rect.width, rect.height)
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: edge / 100, y: edge / 100)
        context.rotate(by: -.pi / 7)
        context.setLineCap(.round)
        let orbit = CGAffineTransform(scaleX: 45, y: 13)
        let planet = CGRect(x: -28, y: -28, width: 56, height: 56)
        let silver = CGColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
        let graphite = CGColor(srgbRed: 0.47, green: 0.47, blue: 0.47, alpha: 1)
        func ring(from start: CGFloat, to end: CGFloat, width: CGFloat, color: CGColor) {
            let arc = CGMutablePath()
            arc.addArc(center: .zero, radius: 1, startAngle: start, endAngle: end,
                       clockwise: false, transform: orbit)
            context.setLineWidth(width)
            context.setStrokeColor(color)
            context.addPath(arc)
            context.strokePath()
        }
        let ink = CGColor(gray: 0, alpha: 1)
        ring(from: -.pi, to: 0, width: 5, color: template ? ink : graphite)
        context.setFillColor(template ? ink : silver)
        context.fillEllipse(in: planet)
        if !template {
            context.saveGState()
            context.addEllipse(in: planet)
            context.clip()
            let colors = [CGColor(srgbRed: 0.985, green: 0.985, blue: 0.985, alpha: 1), silver, graphite] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: colors, locations: [0, 0.48, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: -8, y: -28), end: CGPoint(x: 14, y: 28),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            context.restoreGState()
        }
        // The open seam keeps the ring distinct at menu bar and Spotlight sizes.
        context.saveGState()
        context.addEllipse(in: planet)
        context.clip()
        context.setBlendMode(.clear)
        ring(from: 0, to: .pi, width: template ? 15 : 10, color: ink)
        context.restoreGState()
        ring(from: 0, to: .pi, width: template ? 5.8 : 5, color: template ? ink : silver)
    }
}
