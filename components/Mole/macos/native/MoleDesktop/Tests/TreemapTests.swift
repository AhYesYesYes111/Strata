import AppKit
import SwiftUI

@main struct TreemapTests {
    static func testLivePartitions() {
        typealias Layout = TreemapLayout<String>
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 480)
        let before = Layout([("Users", 50), ("Applications", 49), ("System", 20)], in: bounds, keeping: nil)
        let after = Layout([("Applications", 51), ("Users", 50), ("System", 20)], in: bounds, keeping: before.partition)
        precondition(after.partition == before.partition)
        precondition(abs(after.frames["Users"]!.midX - before.frames["Users"]!.midX) < 3)
        let overtaken = Layout([("System", 90), ("Applications", 51), ("Users", 50)], in: bounds, keeping: after.partition)
        precondition(overtaken.partition == before.partition)
        precondition(overtaken.frames["Applications"]!.maxY <= overtaken.frames["System"]!.minY)

        var page: [Layout.Weight] = (1...12).map { (id: "folder\($0)", bytes: Int64(30 - $0)) }
        page.append(("more", 14))
        let initial = Layout(page, in: bounds, keeping: nil)
        page.removeAll { $0.id == "folder12" }
        page.insert(("promoted", 1000), at: 0)
        let changed = Layout(page, in: bounds, keeping: initial.partition)
        let survivors = Set(page.map(\.id)).subtracting(["promoted"])

        func remaining(_ plan: Layout.Partition) -> Layout.Partition? {
            switch plan {
            case .leaf(let id): return survivors.contains(id) ? plan : nil
            case .split(let axis, let first, let second):
                let left = remaining(first), right = remaining(second)
                if let left, let right { return .split(horizontal: axis, left, right) }
                return left ?? right
            }
        }
        precondition(remaining(initial.partition!) == remaining(changed.partition!))
        precondition(Set(changed.frames.keys) == Set(page.map(\.id)))
        let total = Double(page.reduce(Int64(0)) { $0 + $1.bytes })
        for item in page {
            let rect = changed.frames[item.id]!
            precondition(abs(rect.width * rect.height / (bounds.width * bounds.height) - Double(item.bytes) / total) < 1e-10)
        }
    }

    @MainActor static func main() throws {
        testLivePartitions()
        let palette = ["Users": 0x4A4B4F, "Applications": 0x3D3F43, "System": 0x44464A,
                       "private": 0x383A3E, "Library": 0x424448, "opt": 0x3C3E42]
        for (category, expected) in palette {
            let parent = URL(fileURLWithPath: "/" + category, isDirectory: true)
            let child = parent.appendingPathComponent("example", isDirectory: true)
            precondition(TreemapTone.region(parent).rgb == expected)
            let childRGB = TreemapTone.region(child).rgb
            for shift in [0, 8, 16] {
                precondition(abs(((childRGB >> shift) & 255) - ((expected >> shift) & 255)) <= 4)
            }
            let alias = URL(fileURLWithPath: "/System/Volumes/Data" + child.path, isDirectory: true)
            precondition(TreemapTone.region(alias) == TreemapTone.region(child))
        }
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let names = ["Users", "Applications", "System", "private", "Library", "opt", "usr"]
        let sizes: [Int64] = [135_000, 63_000, 41_000, 15_000, 13_000, 7_500, 350]
        let entries = zip(names, sizes).map { name, bytes in
            DiskEntry(url: root.appendingPathComponent(name, isDirectory: true), isDirectory: true, bytes: bytes, isPartial: false)
        }
        let report = DiskScanResult(root: root, entries: entries, isPartial: false)
        let left = entries[0].url
        for scale in [1.0, 2.0] {
            func render(hover: URL? = nil, selection: URL? = nil) throws -> NSBitmapImageRep {
                let map = TileMap(result: report, offset: 0, nested: false, hovered: hover,
                                  selected: selection, open: { _ in }, more: {}, hover: { _, _ in })
                    .frame(width: 800, height: 480)
                    .environment(\.displayScale, scale)
                    .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: map)
                renderer.scale = scale
                guard let image = renderer.cgImage else { throw CocoaError(.fileReadUnknown) }
                return NSBitmapImageRep(cgImage: image)
            }
            let normal = try render()
            let hovered = try render(hover: left)
            let selected = try render(selection: left)
            let row = Int(30 * scale)
            let split = Int(800 * scale * Double(sizes[0]) / Double(report.totalBytes))
            func rgb(_ bitmap: NSBitmapImageRep, _ column: Int) -> Int {
                var samples = [Int](repeating: 0, count: bitmap.samplesPerPixel)
                precondition(bitmap.bitsPerSample == 8 && samples.count >= 3)
                bitmap.getPixel(&samples, atX: column, y: row)
                return (samples[0] << 16) | (samples[1] << 8) | samples[2]
            }
            if let path = CommandLine.arguments.dropFirst().first, scale == 1 {
                try normal.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            }
            precondition(rgb(normal, 40) == palette["Users"] && rgb(hovered, 40) == 0x525358,
                         String(format: "At %.0fx: base #%06X, hover #%06X", scale, rgb(normal, 40), rgb(hovered, 40)))
            precondition(rgb(selected, 40) == rgb(normal, 40))
            precondition(rgb(hovered, split + 15) == rgb(normal, split + 15))
            let seam = (split - 6)...(split + 6)
            let gutters = seam.filter { rgb(normal, $0) == 0x171719 }
            precondition((2...3).contains(gutters.count))
            precondition(gutters == seam.filter { rgb(hovered, $0) == 0x171719 })
            precondition(seam.contains { rgb(selected, $0) != rgb(normal, $0) })
        }
        print("Passed treemap live rank changes, top-12 turnover, proportional areas, category tones, hover, selection and gutters.")
    }
}
