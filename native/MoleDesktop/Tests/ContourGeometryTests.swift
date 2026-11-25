import SwiftUI

@main
enum ContourGeometryTests {
    static func main() {
        for rect in [CGRect(x: 420, y: -140, width: 960, height: 644),
                     CGRect(x: -100, y: 40, width: 520, height: 1100)] {
            let geometry = ContourGeometry(rect: rect)
            for (index, line) in geometry.lines.enumerated() {
                // Check the middle of every segment, including chunk boundaries
                // and the closing edge. The nearest point must lie on this line.
                for i in line.points.indices {
                    let a = line.points[i], b = line.points[(i + 1) % line.points.count]
                    let midpoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    guard let hit = geometry.nearest(to: midpoint) else { fatalError("Missed segment") }
                    precondition(hit.line == index && abs(hit.pull) < 1e-8)
                    precondition(abs(hit.angle - 2 * .pi * (Double(i) + 0.5) / Double(line.points.count)) < 1e-8)
                }
                precondition(line.restingPath == line.displacedPath { _ in 0 })
            }
            precondition(geometry.nearest(to: CGPoint(x: -10000, y: -10000)) == nil)
        }
        print("PASS cached paths, resized geometry, hover segments and misses")
    }
}
