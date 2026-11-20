import CoreGraphics
import Foundation
import SwiftUI

/// An orthographic Earth with a separately drawn orbital tracker.
struct OrbitArtwork: View {
    var isScanning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var globe: CGImage?
    private static let texture = Task.detached(priority: .userInitiated) { GlobeRenderer().render() }

    var body: some View {
        GeometryReader { geometry in
            let orbit = OrbitProjection(size: geometry.size)
            ZStack {
                Canvas { context, _ in
                    context.stroke(orbit.track(), with: .color(.cyan.opacity(0.28)), lineWidth: 0.8)
                    context.stroke(orbit.track(scale: 1.10), with: .color(.white.opacity(0.18)),
                                   style: StrokeStyle(lineWidth: 0.65, dash: [1, 5]))
                }
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.18, green: 0.48, blue: 0.52),
                                                  Color(red: 0.02, green: 0.08, blue: 0.13)],
                                         center: .topLeading, startRadius: 0, endRadius: orbit.diameter))
                    .frame(width: orbit.diameter * 0.98, height: orbit.diameter * 0.98)
                    .shadow(color: .cyan.opacity(0.23), radius: orbit.diameter * 0.075)
                if let globe {
                    Image(decorative: globe, scale: 2).resizable().interpolation(.high)
                        .frame(width: orbit.diameter, height: orbit.diameter)
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
        .task { globe = await Self.texture.value }
    }

    private func overlay(_ orbit: OrbitProjection, elapsed: TimeInterval) -> some View {
        Canvas { context, _ in
            let cycle = elapsed.truncatingRemainder(dividingBy: 55) / 55
            let angle = 0.45 + 2 * .pi * cycle
            let position = orbit.position(angle)
            // Fade the tracker behind the Earth's limb as it enters the far half.
            let offset = hypot(position.x - orbit.center.x, position.y - orbit.center.y)
            let visibility = sin(angle) >= 0 ? 1 : min(1, max(0, (offset - orbit.diameter * 0.492) / 4))
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
        let radius = diameter * 0.489
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

private struct GlobeRenderer {
    // Hand-drawn longitude/latitude silhouettes. Smaller coast features are generated as terrain noise.
    private let shores: [[SIMD2<Double>]] = [
        [[-168,71],[-148,70],[-130,69],[-126,72],[-111,70],[-103,74],[-88,72],[-81,68],[-86,63],[-95,63],[-96,58],[-85,55],[-79,61],[-77,63],[-69,61],[-63,58],[-59,54],[-55,52],[-58,50],[-64,49],[-68,47],[-63,45],[-66,44],[-71,43],[-74,40],[-76,38],[-75,35],[-80,31],[-80,26],[-82,25],[-84,30],[-88,30],[-90,29],[-94,30],[-97,26],[-97,22],[-95,19],[-91,18],[-89,22],[-87,21],[-88,17],[-85,16],[-82,15],[-83,11],[-79,9],[-77,8],[-79,7],[-83,9],[-86,12],[-90,14],[-95,16],[-101,18],[-106,20],[-110,24],[-111,30],[-114,32],[-109,23],[-112,24],[-117,32],[-122,37],[-125,42],[-124,48],[-128,51],[-135,58],[-143,60],[-151,60],[-154,58],[-165,54],[-160,60],[-167,63]],
        [[-81,12],[-75,11],[-72,13],[-69,12],[-65,10],[-61,11],[-60,8],[-56,6],[-52,4],[-50,1],[-48,-1],[-44,-2],[-41,-3],[-37,-5],[-35,-8],[-38,-14],[-39,-18],[-41,-22],[-44,-23],[-48,-25],[-49,-29],[-52,-33],[-55,-35],[-58,-35],[-57,-38],[-62,-41],[-64,-42],[-65,-46],[-67,-49],[-66,-53],[-69,-55],[-73,-54],[-75,-50],[-74,-45],[-73,-43],[-72,-39],[-72,-34],[-71,-29],[-70,-24],[-70,-19],[-73,-16],[-76,-14],[-78,-10],[-80,-7],[-81,-5],[-79,-2],[-80,1],[-78,3],[-77,7]],
        [[-17,14],[-16,19],[-17,21],[-14,26],[-12,28],[-10,30],[-9,33],[-6,36],[-2,35],[0,36],[7,37],[10,37],[12,33],[16,31],[20,32],[23,32],[26,31],[32,31],[34,27],[37,22],[38,17],[43,12],[50,12],[51,10],[48,5],[43,0],[41,-3],[40,-10],[41,-15],[37,-18],[35,-20],[35,-24],[32,-26],[31,-30],[28,-32],[24,-34],[19,-35],[17,-32],[16,-29],[14,-24],[13,-19],[12,-16],[13,-12],[13,-9],[12,-6],[9,-3],[9,1],[10,4],[7,4],[5,5],[1,6],[-4,5],[-8,4],[-11,6],[-13,8],[-15,11]],
        [[-10,37],[-9,43],[-6,44],[-2,43],[-1,46],[-5,48],[-4,49],[0,49],[2,51],[4,52],[7,53],[8,56],[10,58],[10,54],[13,55],[15,54],[18,55],[20,55],[22,57],[24,60],[29,60],[25,62],[21,63],[23,66],[18,65],[17,61],[14,57],[12,56],[11,59],[7,58],[5,59],[5,62],[9,64],[13,67],[16,68],[20,70],[26,71],[31,71],[34,69],[40,68],[41,64],[45,68],[54,69],[61,71],[78,72],[93,76],[107,77],[115,74],[128,73],[143,73],[160,69],[176,68],[179,61],[162,58],[157,51],[144,48],[138,43],[131,42],[128,37],[125,38],[123,40],[119,39],[121,33],[120,29],[117,24],[110,21],[107,19],[108,15],[105,10],[102,13],[98,16],[98,9],[103,2],[100,4],[96,11],[94,17],[91,22],[88,22],[86,20],[82,16],[77,8],[75,11],[72,18],[69,21],[65,25],[58,26],[55,26],[56,23],[59,22],[57,18],[51,15],[47,13],[44,12],[42,14],[40,18],[37,22],[34,29],[33,30],[36,35],[32,36],[28,37],[26,40],[23,41],[24,38],[22,36],[20,39],[18,41],[15,44],[13,45],[16,41],[17,40],[16,38],[14,40],[12,42],[10,44],[8,44],[6,43],[3,43],[1,41],[-1,39],[-5,36]],
        [[-73,79],[-66,82],[-55,83],[-39,83],[-22,82],[-14,80],[-19,76],[-18,73],[-21,70],[-26,69],[-31,67],[-38,65],[-43,61],[-45,59],[-49,62],[-51,66],[-54,68],[-51,70],[-56,73],[-59,76],[-65,77]],
        [[-8,50],[-5,50],[-3,51],[1,51],[2,53],[-1,54],[-2,55],[-3,56],[-1,58],[-5,59],[-6,57],[-5,55],[-3,54],[-5,53]],
        [[-11,52],[-10,54],[-8,55],[-6,55],[-6,53],[-7,52]],
        [[-25,65],[-22,66.5],[-16,66],[-13,65],[-18,63.4],[-22,64]],
        [[-88,80],[-79,83],[-67,82],[-73,78],[-78,76],[-82,77]],
        [[-79,74],[-73,73],[-63,69],[-61,66],[-66,63],[-72,64],[-68,66],[-74,68],[-78,70],[-82,72]],
        [[-85,22],[-80,23],[-77,21],[-74,20],[-78,20]], [[-75,20],[-71,20],[-68,18],[-73,18]],
        [[43,-22],[44,-17],[49,-12],[50,-16],[47,-25],[45,-26]],
        [[-180,-76],[-120,-73],[-86,-74],[-64,-64],[-59,-67],[-60,-75],[-30,-78],[-7,-71],[22,-69],[55,-67],[93,-66],[119,-67],[154,-69],[180,-78],[180,-90],[-180,-90]]
    ]

    private let textureWidth = 1000
    private let noise: [Double]
    private let land: [UInt8]

    init() {
        var seed: UInt32 = 0x4d4c_4154
        noise = (0..<(256 * 256)).map { _ in
            seed = 1_664_525 &* seed &+ 1_013_904_223
            return Double(seed >> 8) / 16_777_216
        }
        let height = textureWidth / 2
        var pixels = [UInt8](repeating: 0, count: textureWidth * height)
        for polygon in shores {
            for row in 0..<height {
                let latitude = 90 - Double(row) * 180 / Double(height)
                var intersections: [Double] = []
                var prior = polygon.last!
                for p in polygon {
                    if (p.y > latitude) != (prior.y > latitude) { intersections.append(p.x + (latitude - p.y) * (prior.x - p.x) / (prior.y - p.y)) }
                    prior = p
                }
                intersections.sort()
                for i in stride(from: 1, to: intersections.count, by: 2) {
                    let start = max(0, Int((intersections[i - 1] + 180) / 360 * Double(textureWidth)))
                    let end = min(textureWidth, Int((intersections[i] + 180) / 360 * Double(textureWidth)))
                    for x in start..<end { pixels[row * textureWidth + x] = 1 }
                }
            }
        }
        land = pixels
    }

    private func grain(_ x: Double, _ y: Double) -> Double {
        let i = Int(floor(x)), j = Int(floor(y))
        let dx = x - floor(x), dy = y - floor(y)
        let a = dx * dx * (3 - 2 * dx), b = dy * dy * (3 - 2 * dy)
        let k = (j & 255) * 256, l = ((j + 1) & 255) * 256
        let left = noise[k + (i & 255)] * (1 - b) + noise[l + (i & 255)] * b
        let right = noise[k + ((i + 1) & 255)] * (1 - b) + noise[l + ((i + 1) & 255)] * b
        return left * (1 - a) + right * a
    }

    private func surface(_ x: Double, _ y: Double) -> Double {
        grain(x, y) * 0.47 + grain(x * 2.04 + 23, y * 2.04) * 0.28 + grain(x * 4.2, y * 4.2 + 37) * 0.17 + grain(x * 8.3 + 54, y * 8.3) * 0.08
    }

    private func isLand(_ longitude: Double, _ latitude: Double) -> Bool {
        let height = textureWidth / 2
        let i = min(textureWidth - 1, max(0, Int((longitude + 180) / 360 * Double(textureWidth))))
        let j = min(height - 1, max(0, Int((90 - latitude) / 180 * Double(height))))
        return land[j * textureWidth + i] != 0
    }

    func render() -> CGImage? {
        let side = 560, radius = Double(side) * 0.492, center = Double(side) / 2
        let angle = 18.0 * Double.pi / 180, tilt = -0.12
        let sinAngle = sin(angle), cosAngle = cos(angle), cosTilt = cos(tilt), sinTilt = sin(tilt)
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for row in 0..<side {
            let y = (center - Double(row) - 0.5) / radius
            for column in 0..<side {
                let x = (Double(column) + 0.5 - center) / radius
                let distance = x * x + y * y
                guard distance < 1 else { continue }
                let z = sqrt(1 - distance)
                let ax = x * cosTilt - y * sinTilt, ay = x * sinTilt + y * cosTilt
                let lat = asin(min(1, max(-1, ay * cosAngle + z * sinAngle))) * 180 / .pi
                let lon = atan2(ax, z * cosAngle - ay * sinAngle) * 180 / .pi - 30
                let terrain = surface(lon * 0.15, lat * 0.19)
                let n = terrain - 0.5
                let detail = grain(lon * 2.7, lat * 3.2) - 0.5
                let coastX = lon + n * 3.0
                let coastY = lat + (grain(lon * 0.72, lat * 0.77) - 0.5) * 1.5
                let landHere = isLand(coastX, coastY)
                var color: SIMD3<Double>
                if landHere {
                    let dry = max(0, 1 - abs(lat - 24) / 15) * (lon > -19 ? 1 : 0.36)
                    color = SIMD3(79, 136, 112) + dry * SIMD3(115, 36, -6) + n * SIMD3(122, 114, 84)
                    color += detail * SIMD3(20, 23, 18)
                    if lat > 64 + n * 7 { color = SIMD3(177, 207, 217) + terrain * SIMD3(48, 37, 34) }
                } else {
                    let tropics = max(0, 1 - abs(lat - 3) / 56)
                    color = SIMD3(23, 67, 103) + tropics * SIMD3(-8, 20, 15) + n * SIMD3(18, 34, 36)
                    if isLand(coastX + 0.85, coastY + 0.45) { color += SIMD3(13, 28, 17) }
                }
                // Distort broad cloud banks slightly at the scale of fronts, then
                // break their edges into smaller patches. Terrain remains legible.
                let drift = 3.5 * sin(lon * 0.07 + 2 * sin(lat * 0.08))
                let weather = surface(lon * 0.080, (lat + drift) * 0.18)
                let wisps = grain(lon * 0.43, (lat + drift) * 0.82) - 0.5
                let clouds = min(0.83, max(0, (weather + wisps * 0.14 - 0.51) * 2.5))
                color += (SIMD3(228, 238, 237) - color) * clouds

                let light = -0.62 * x + 0.65 * y + 0.44 * z
                let direct = max(0, light)
                color *= SIMD3(repeating: 0.16 + 1.03 * pow(direct, 0.68))
                let rim = pow(1 - z, 3.2) * (0.3 + 0.7 * direct)
                color += SIMD3(102, 179, 203) * rim
                // Sunlight reflected along the Atlantic surface, reduced under clouds.
                if !landHere {
                    let reflection = pow(max(0, -0.365 * x + 0.383 * y + 0.85 * z), 36)
                    color += SIMD3(41, 50, 45) * reflection * (1 - clouds)
                }
                let alpha = min(1, (1 - sqrt(distance)) * radius)
                let index = (row * side + column) * 4
                for channel in 0..<3 { pixels[index + channel] = UInt8(min(255, max(0, color[channel])) * alpha) }
                pixels[index + 3] = UInt8(255 * alpha)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
