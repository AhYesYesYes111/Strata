import Foundation
import CoreGraphics

func reliefLine(in size: CGSize, level: Double) -> CGPath {
    let unit = min(size.width * 0.48, size.height * 0.48)
    let center = CGPoint(x: size.width * 0.50, y: size.height * 0.52)
    let path = CGMutablePath()
    for step in 0...160 {
        let angle = 2 * Double.pi * Double(step) / 160
        let shape = 1 + 0.105 * sin(3 * angle + 2.5 * level) + 0.085 * cos(2 * angle - level)
            + 0.037 * cos(5 * angle + level) + 0.018 * sin(7 * angle - 3 * level)
        let radius = unit * (0.06 + 0.93 * level) * shape
        let x = center.x + cos(angle) * radius * 1.10 + unit * 0.19 * (1 - level)
        let y = center.y + sin(angle) * radius * 0.78 - unit * 0.21 * (1 - level) - 0.24 * (x - center.x)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}
