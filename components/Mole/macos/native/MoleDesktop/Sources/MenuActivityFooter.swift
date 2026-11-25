import CoreAudio
import CoreMediaIO
import Darwin
import IOKit.pwr_mgt
import SwiftUI

/// Session-end markers carry clean bytes (rounded by the CLI), successful app
/// uninstalls, and applied maintenance tasks. Individual file rows overlap them.
struct MenuActivityTotals: Equatable {
    var cleaned: Int64 = 0
    var uninstalled = 0
    var optimized = 0

    private static let endMarker = try! NSRegularExpression(pattern:
        #"^# ========== (clean|uninstall|optimize) run=([A-Za-z0-9._-]+) session ended at [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}, ([0-9]+) items, ([0-9]+(?:\.[0-9]+)?)(GB|MB|KB|B) ==========$"#)

    private static let appliedRow = try! NSRegularExpression(pattern:
        #"^\[[0-9-]+ [0-9:]+\] \[(clean|uninstall|optimize) run=([A-Za-z0-9._-]+)\] (REMOVED|TRASHED|REBUILT) "#)

    static func read(from url: URL) -> Self? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { return nil }
        let limit = 1_048_576
        let offset = max(0, info.st_size - Int64(limit))
        do {
            try file.seek(toOffset: UInt64(max(0, offset - 1)))
            guard var data = try file.read(upToCount: limit + (offset > 0 ? 1 : 0)), let end = data.lastIndex(of: 10) else { return Self() }
            data = data[..<end]
            if offset > 0 {
                guard let newline = data.firstIndex(of: 10) else { return Self() }
                data = data.suffix(from: data.index(after: newline))
            }
            return parse(data)
        } catch {
            return nil
        }
    }

    static func parse(_ data: Data) -> Self {
        var total = Self()
        let units: [Substring: Double] = ["GB": 1e9, "MB": 1e6, "KB": 1e3, "B": 1]
        // Older engines did not identify previews in their session markers.
        // Require an actual change under the same run ID to corroborate a total.
        var appliedRuns = Set<String>()
        for raw in data.split(separator: 10) {
            if raw.first == 91 {
                let prefix = String(decoding: raw.prefix(256), as: UTF8.self)
                if let row = appliedRow.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
                   let command = Range(row.range(at: 1), in: prefix), let id = Range(row.range(at: 2), in: prefix) {
                    appliedRuns.insert(prefix[command] + "/" + prefix[id])
                }
                continue
            }
            guard raw.first == 35 && raw.count <= 512 else { continue }
            let line = String(decoding: raw, as: UTF8.self)
            guard let match = endMarker.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let commandRange = Range(match.range(at: 1), in: line),
                  let id = Range(match.range(at: 2), in: line),
                  let itemsRange = Range(match.range(at: 3), in: line),
                  let sizeRange = Range(match.range(at: 4), in: line),
                  let unitRange = Range(match.range(at: 5), in: line),
                  let count = Int(line[itemsRange]), let size = Double(line[sizeRange]),
                  let multiplier = units[line[unitRange]],
                  appliedRuns.remove(line[commandRange] + "/" + line[id]) != nil else { continue }
            switch line[commandRange] {
            case "clean":
                guard let bytes = Int64(exactly: (size * multiplier).rounded()), bytes <= Int64.max - total.cleaned else { continue }
                total.cleaned += bytes
            case "uninstall" where count <= Int.max - total.uninstalled: total.uninstalled += count
            case "optimize" where count <= Int.max - total.optimized: total.optimized += count
            default: continue
            }
        }
        return total
    }
}

// These HAL properties describe devices and current I/O. No stream is opened.
private enum InputHardware {
    case camera, audio

    private func words(object: UInt32, selector: UInt32, scope: UInt32) -> [UInt32]? {
        var size: UInt32 = 0
        var audio = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
        var camera = CMIOObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
        let status = self == .camera
            ? CMIOObjectGetPropertyDataSize(object, &camera, 0, nil, &size)
            : AudioObjectGetPropertyDataSize(object, &audio, 0, nil, &size)
        guard status == noErr, size <= 4_096, size.isMultiple(of: 4) else { return nil }
        guard size > 0 else { return [] }
        var words = [UInt32](repeating: 0, count: Int(size / 4))
        var used = size
        let result = words.withUnsafeMutableBytes { buffer in
            self == .camera
                ? CMIOObjectGetPropertyData(object, &camera, 0, nil, size, &used, buffer.baseAddress!)
                : AudioObjectGetPropertyData(object, &audio, 0, nil, &used, buffer.baseAddress!)
        }
        guard result == noErr, used <= size, used.isMultiple(of: 4) else { return nil }
        return Array(words.prefix(Int(used / 4)))
    }

    func activity() -> Bool? {
        let camera = self == .camera
        let system = camera ? UInt32(kCMIOObjectSystemObject) : UInt32(kAudioObjectSystemObject)
        let list = camera ? UInt32(kCMIOHardwarePropertyDevices) : UInt32(kAudioHardwarePropertyDevices)
        let global = camera ? UInt32(kCMIOObjectPropertyScopeGlobal) : UInt32(kAudioObjectPropertyScopeGlobal)
        let streams = camera ? UInt32(kCMIODevicePropertyStreams) : UInt32(kAudioDevicePropertyStreams)
        let input = camera ? UInt32(kCMIODevicePropertyScopeInput) : UInt32(kAudioObjectPropertyScopeInput)
        let output = camera ? UInt32(kCMIODevicePropertyScopeOutput) : UInt32(kAudioObjectPropertyScopeOutput)
        let running = camera ? UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere) : UInt32(kAudioDevicePropertyDeviceIsRunningSomewhere)
        guard let devices = words(object: system, selector: list, scope: global) else { return nil }
        var foundInput = false
        var uncertain = false
        for device in devices {
            guard let inputs = words(object: device, selector: streams, scope: input) else { uncertain = true; continue }
            guard !inputs.isEmpty else { continue }
            foundInput = true
            guard let active = words(object: device, selector: running, scope: global)?.first else { uncertain = true; continue }
            guard active != 0 else { continue }
            // RunningSomewhere is device-wide. Playback on a duplex interface
            // cannot prove that its microphone is capturing.
            if words(object: device, selector: streams, scope: output)?.isEmpty == true { return true }
            uncertain = true
        }
        return foundInput && !uncertain ? false : nil
    }
}

private struct MenuSystemActivity {
    var camera: Bool?
    var microphone: Bool?
    var awake: Bool?
    var display: Bool?

    static func read() -> Self {
        var result = Self(camera: InputHardware.camera.activity(), microphone: InputHardware.audio.activity())
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&unmanaged) == kIOReturnSuccess,
              let status = unmanaged?.takeRetainedValue() as? [String: NSNumber] else { return result }
        let system = status[kIOPMAssertionTypePreventSystemSleep as String]?.boolValue
        let idle = status[kIOPMAssertionTypePreventUserIdleSystemSleep as String]?.boolValue
        if system == true || idle == true { result.awake = true }
        else if system != nil && idle != nil { result.awake = false }
        result.display = status[kIOPMAssertionTypePreventUserIdleDisplaySleep as String]?.boolValue
        return result
    }
}

struct MenuActivityFooter: View {
    @State private var activity = MenuSystemActivity()
    @State private var history: MenuActivityTotals?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "video")
                    Image(systemName: "mic")
                    Text(inputSummary)
                }.font(.system(size: 10, weight: .medium))
                    .foregroundStyle(activity.camera == true || activity.microphone == true ? StrataColor.accent : StrataColor.muted)
                    .accessibilityLabel(inputDetails).help(inputDetails)
                Spacer(minLength: 0)
                indicator("cup.and.saucer", activity.awake == true ? tr("防休眠", "Sleep held") : tr("可休眠", "Can sleep"),
                          tr("休眠", "Sleep"), activity.awake)
                indicator("display", activity.display == true ? tr("防熄屏", "Display held") : tr("可熄屏", "Can dim"),
                          tr("屏幕", "Display"), activity.display)
            }
            Divider()
            Text(tr("近期操作", "Recent activity")).font(.caption).foregroundStyle(StrataColor.muted)
            HStack(spacing: 8) {
                total(history.map { storageSize($0.cleaned) }, tr("已清理", "Cleaned"))
                total(history.map { String($0.uninstalled) }, tr("已卸载应用", "Apps removed"))
                total(history.map { String($0.optimized) }, tr("维护任务", "Tasks applied"))
            }
            .help(history == nil ? tr("没有可读取的 Mole 操作日志。", "No readable Mole operation log.")
                : tr("仅统计当前 Mole 日志最后 1 MiB 内可核实的已执行操作。清理空间为近似值。",
                     "Completed runs with recorded changes in the last 1 MiB of the current Mole log. Cleaned space is approximate."))
        }
        .padding(12)
        .background(StrataColor.panel, in: RoundedRectangle(cornerRadius: 12))
        .task {
            let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/mole/operations.log")
            let totals = await Task.detached(priority: .utility) { MenuActivityTotals.read(from: log) }.value
            guard !Task.isCancelled else { return }
            history = totals
            while !Task.isCancelled {
                let next = await Task.detached(priority: .utility) { MenuSystemActivity.read() }.value
                guard !Task.isCancelled else { return }
                activity = next
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
            }
        }
    }

    private func state(_ active: Bool?) -> String {
        active.map { $0 ? tr("活动中", "Active") : tr("空闲", "Idle") } ?? tr("未知", "Unknown")
    }

    private var inputDetails: String {
        tr("相机", "Camera") + " · " + state(activity.camera) + "    " + tr("麦克风", "Mic") + " · " + state(activity.microphone)
    }

    private var inputSummary: String {
        switch (activity.camera, activity.microphone) {
        case (true, true): return tr("影音使用中", "Both active")
        case (true, _): return tr("相机使用中", "Camera active")
        case (_, true): return tr("麦克风使用中", "Mic active")
        case (false, false): return tr("空闲", "Idle")
        default: return tr("状态未知", "Unknown")
        }
    }

    private func indicator(_ symbol: String, _ name: String, _ unknownName: String, _ active: Bool?) -> some View {
        return HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(active == nil ? unknownName + " ?" : name)
        }.font(.system(size: 10, weight: .medium))
            .foregroundStyle(active == true ? StrataColor.accent : StrataColor.muted)
            .accessibilityElement(children: .combine)
            .help(active == nil ? unknownName + " · " + state(nil) : name)
    }

    private func total(_ value: String?, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—").font(.system(size: 16, weight: .semibold)).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(StrataColor.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}
