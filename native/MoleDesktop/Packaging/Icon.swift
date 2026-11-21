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
                context.clip()
                let background = CGGradient(colorsSpace: colorSpace, colors: [
                    CGColor(srgbRed: 0.222, green: 0.222, blue: 0.222, alpha: 1),
                    CGColor(srgbRed: 0.080, green: 0.080, blue: 0.080, alpha: 1)
                ] as CFArray, locations: [0, 1])!
                context.drawLinearGradient(background, start: CGPoint(x: 100, y: 476),
                                           end: CGPoint(x: 343, y: 32), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.addPath(base)
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
                context.setLineWidth(4)
                context.strokePath()
                context.translateBy(x: 0, y: 512)
                context.scaleBy(x: 1, y: -1)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                ContourMark.draw(in: context, rect: CGRect(x: 57, y: 57, width: 398, height: 398))
                context.endTransparencyLayer()
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
