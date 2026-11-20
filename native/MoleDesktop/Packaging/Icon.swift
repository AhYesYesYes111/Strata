import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct Icon {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
                context.scaleBy(x: CGFloat(pixels) / 512, y: CGFloat(pixels) / 512)
                let base = CGPath(roundedRect: CGRect(x: 32, y: 32, width: 448, height: 448),
                                  cornerWidth: 102, cornerHeight: 102, transform: nil)
                context.addPath(base)
                context.setFillColor(CGColor(srgbRed: 0.068, green: 0.16, blue: 0.135, alpha: 1))
                context.fillPath()
                context.translateBy(x: 72, y: 434)
                context.scaleBy(x: 1, y: -1)
                let count = points < 64 ? 4 : 10
                for index in 1...count {
                    let level = CGFloat(index) / CGFloat(count)
                    context.addPath(reliefLine(in: CGSize(width: 360, height: 360), level: level))
                    context.setStrokeColor(CGColor(srgbRed: 0.84 - 0.24 * level, green: 0.90, blue: 0.66, alpha: 1))
                    context.setLineWidth(points < 64 ? 14 : 6.5)
                    context.strokePath()
                }
                let file = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
                let url = directory.appendingPathComponent(file)
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil),
                      let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }
}
