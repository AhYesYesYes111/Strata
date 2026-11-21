import AppKit
import SwiftUI

enum StrataColor {
    static let paper = Color(red: 0.071, green: 0.075, blue: 0.079)
    static let panel = Color(red: 0.122, green: 0.127, blue: 0.133)
    static let rail = Color(red: 0.081, green: 0.094, blue: 0.092)
    static let ink = Color(red: 0.955, green: 0.955, blue: 0.944)
    static let muted = Color(red: 0.708, green: 0.719, blue: 0.714)
    static let accent = Color(red: 0.558, green: 0.804, blue: 0.710)
    static let mint = Color(red: 0.719, green: 0.913, blue: 0.817)
    static let border = Color.white.opacity(0.115)
}

struct PageTitle: View {
    let title: String
    let detail: String
    init(_ title: String, detail: String) { self.title = title; self.detail = detail }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 29, weight: .semibold)).tracking(-0.5)
            Text(detail).font(.system(size: 13)).foregroundStyle(StrataColor.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content().padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(StrataColor.panel, in: shape)
            .overlay(shape.strokeBorder(StrataColor.border, lineWidth: 0.75).allowsHitTesting(false))
    }
}

struct ActionStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 15).padding(.vertical, 9)
            .foregroundColor(isPrimary ? StrataColor.rail : StrataColor.ink)
            .background(isPrimary ? StrataColor.mint : Color.white.opacity(0.045), in: shape)
            .overlay(shape.strokeBorder(isPrimary ? Color.clear : StrataColor.border, lineWidth: 0.75))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.42)
    }
}

func storageSize(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .decimal, spellsOutZero: false).locale(AppLanguage.current.locale))
}

func powerReading(_ watts: Double) -> String {
    guard watts.isFinite, watts >= 0 else { return "—" }
    if watts == 0 { return "0 W" }
    if watts < 0.001 { return "<1 mW" }
    if watts < 0.1 { return String(Int((watts * 1000).rounded())) + " mW" }
    return watts.formatted(.number.locale(AppLanguage.current.locale).precision(.fractionLength(0...2))) + " W"
}

struct VolumeReading {
    let volume: String
    let capacity: Int64
    let free: Int64
    var used: Int64 { capacity - free }
    var fraction: Double { Double(used) / Double(capacity) }

    static func read() -> VolumeReading? {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        guard let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey]),
              let capacity = values.volumeTotalCapacity, capacity > 0 else { return nil }
        // macOS includes reclaimable space in its capacity for important usage.
        let important = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let candidates = [important, values.volumeAvailableCapacity.map { Int64($0) }]
        guard let free = candidates.compactMap({ $0 }).filter({ (0...Int64(capacity)).contains($0) }).max() else { return nil }
        return VolumeReading(volume: values.volumeName ?? root.path, capacity: Int64(capacity), free: free)
    }
}

struct NavigationPlanet: View {
    var body: some View {
        Canvas { context, size in
            context.withCGContext { PlanetMark.draw(in: $0, rect: CGRect(origin: .zero, size: size)) }
        }.accessibilityHidden(true)
    }
}

func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
