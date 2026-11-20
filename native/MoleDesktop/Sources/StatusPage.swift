import AppKit
import Charts
import Darwin
import IOKit.ps
import SwiftUI
import SystemConfiguration

struct ProcessorSample {
    let ticks: (UInt32, UInt32, UInt32, UInt32)

    static func read() -> Self? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Self(ticks: info.cpu_ticks)
    }

    func usage(since prev: Self) -> Double? {
        let busy = UInt64(ticks.0 &- prev.ticks.0) + UInt64(ticks.1 &- prev.ticks.1) + UInt64(ticks.3 &- prev.ticks.3)
        let total = busy + UInt64(ticks.2 &- prev.ticks.2)
        return total > 0 ? Double(busy) / Double(total) : nil
    }
}

struct CapacitySample {
    let used: UInt64
    let total: UInt64
    var fraction: Double { Double(used) / Double(total) }

    static func memory() -> Self? {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard status == KERN_SUCCESS, total > 0 else { return nil }
        let appPages = UInt64(vm.internal_page_count - min(vm.internal_page_count, vm.purgeable_count))
        let used = (appPages + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * UInt64(vm_kernel_page_size)
        return Self(used: min(used, total), total: total)
    }

    static func disk() -> Self? {
        let volume = URL(fileURLWithPath: "/")
        let sizes = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard let total = sizes?.volumeTotalCapacity, let free = sizes?.volumeAvailableCapacity, total > 0, free >= 0, free <= total else { return nil }
        return Self(used: UInt64(total - free), total: UInt64(total))
    }
}

struct ResourceSample {
    let date: Date
    let cpu: Double?
    let memory: Double?
}

struct ResourceTrend {
    static let duration: TimeInterval = 60
    static let longestInterval: TimeInterval = 5
    private(set) var samples: [ResourceSample] = []

    mutating func append(_ sample: ResourceSample) {
        if let last = samples.last, last.date >= sample.date { samples.removeAll(keepingCapacity: true) }
        samples.removeAll { sample.date.timeIntervalSince($0.date) > Self.duration }
        samples.append(sample)
        // The 2-second sampler normally supplies 31 points including the two endpoints.
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }
    }

    struct Point: Identifiable {
        let date: Date
        let offset: Double
        let percent: Double
        let segment: Int
        var id: Date { date }
    }

    func points(for metric: KeyPath<ResourceSample, Double?>) -> [Point] {
        guard let latest = samples.last?.date else { return [] }
        var points: [Point] = []
        var previous: Date?
        var segment = 0
        for sample in samples {
            guard let value = sample[keyPath: metric], value.isFinite, (0...1).contains(value) else {
                previous = nil
                continue
            }
            if previous.map({ sample.date.timeIntervalSince($0) > Self.longestInterval }) ?? true {
                segment += 1
            }
            points.append(Point(date: sample.date, offset: sample.date.timeIntervalSince(latest),
                                percent: value * 100, segment: segment))
            previous = sample.date
        }
        return points
    }
}

struct BatteryReading {
    let charge: Double?
    let supply: Supply

    enum Supply {
        case reading, unavailable, charging, adapter, battery, unknown, absent

        var description: String {
            switch self {
            case .reading: return tr("正在读取", "Reading…")
            case .unavailable: return tr("电源信息不可用", "Power source unavailable")
            case .charging: return tr("正在充电", "Charging")
            case .adapter: return tr("电源适配器供电", "Power adapter connected")
            case .battery: return tr("电池供电", "On battery")
            case .unknown: return tr("供电状态未知", "Unknown power source")
            case .absent: return tr("未检测到内置电池", "No built-in battery")
            }
        }
    }

    static func read() -> Self {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return Self(charge: nil, supply: .unavailable)
        }
        for source in sources {
            guard let battery = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  battery[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let charged = battery[kIOPSIsChargingKey] as? Bool ?? false
            let state = battery[kIOPSPowerSourceStateKey] as? String
            let supply: Supply
            if charged { supply = .charging }
            else if state == kIOPSACPowerValue { supply = .adapter }
            else if state == kIOPSBatteryPowerValue { supply = .battery }
            else { supply = .unknown }
            guard let current = battery[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = battery[kIOPSMaxCapacityKey] as? Double,
                  maximum > 0, (0...maximum).contains(current) else { return Self(charge: nil, supply: supply) }
            return Self(charge: current / maximum, supply: supply)
        }
        return Self(charge: nil, supply: .absent)
    }
}

struct LinkCounters {
    let name: String
    let received: UInt64
    let sent: UInt64

    static func read(from store: SCDynamicStore?) -> Self? {
        guard let store else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            guard let network = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let name = network[kSCDynamicStorePropNetPrimaryInterface as String] as? String else { continue }
            let index = if_nametoindex(name)
            guard index != 0 else { continue }
            var keys: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
            var counters = ifmibdata()
            var count = MemoryLayout.size(ofValue: counters)
            guard sysctl(&keys, UInt32(keys.count), &counters, &count, nil, 0) == 0,
                  count == MemoryLayout.size(ofValue: counters) else { continue }
            return Self(name: name, received: counters.ifmd_data.ifi_ibytes, sent: counters.ifmd_data.ifi_obytes)
        }
        return nil
    }

    func rate(since previous: Self?, seconds: TimeInterval) -> (down: Double, up: Double)? {
        guard let previous, previous.name == name, seconds > 0, seconds <= ResourceTrend.longestInterval,
              received >= previous.received, sent >= previous.sent else { return nil }
        return (Double(received - previous.received) / seconds, Double(sent - previous.sent) / seconds)
    }
}

private func chipName() -> String {
    for key in ["machdep.cpu.brand_string", "hw.model"] {
        var length = 0
        guard sysctlbyname(key, nil, &length, nil, 0) == 0, (1...512).contains(length) else { continue }
        var bytes = [CChar](repeating: 0, count: length)
        if sysctlbyname(key, &bytes, &length, nil, 0) == 0, bytes.contains(0) {
            let name = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
    }
    return "Mac"
}

struct StatusReadings {
    let chip = chipName()
    private let networkStore = SCDynamicStoreCreate(nil, "Strata Status" as CFString, nil, nil)
    private var cpuCounter: ProcessorSample?
    private var linkCounter: LinkCounters?
    private(set) var cpu: Double?
    private(set) var warmingUp = true
    private(set) var memory: CapacitySample?
    private(set) var disk: CapacitySample?
    private(set) var battery = BatteryReading(charge: nil, supply: .reading)
    private(set) var link: String?
    private(set) var throughput: (down: Double, up: Double)?
    private(set) var trend = ResourceTrend()
    private(set) var uptime: TimeInterval?
    private(set) var thermal: ProcessInfo.ThermalState?

    mutating func sample() {
        let now = Date()
        let elapsed = trend.samples.last.map { now.timeIntervalSince($0.date) } ?? 0
        let continuous = elapsed > 0 && elapsed <= ResourceTrend.longestInterval
        let current = ProcessorSample.read()
        cpu = continuous ? cpuCounter.flatMap { current?.usage(since: $0) } : nil
        warmingUp = current != nil && (!continuous || cpuCounter == nil)
        cpuCounter = current
        let counters = LinkCounters.read(from: networkStore)
        throughput = counters?.rate(since: linkCounter, seconds: elapsed)
        link = counters?.name
        linkCounter = counters
        memory = CapacitySample.memory()
        disk = CapacitySample.disk()
        battery = BatteryReading.read()
        var boot = timeval()
        var bootBytes = MemoryLayout.size(ofValue: boot)
        if sysctlbyname("kern.boottime", &boot, &bootBytes, nil, 0) == 0, boot.tv_sec > 0 {
            uptime = max(0, now.timeIntervalSince1970 - Double(boot.tv_sec))
        } else {
            uptime = nil
        }
        thermal = ProcessInfo.processInfo.thermalState
        trend.append(ResourceSample(date: now, cpu: cpu, memory: memory?.fraction))
    }
}

private let jade = Color(red: 0.51, green: 0.88, blue: 0.76)
private let lilac = Color(red: 0.77, green: 0.73, blue: 0.99)
private let amber = Color(red: 0.97, green: 0.78, blue: 0.50)
private let sky = Color(red: 0.55, green: 0.78, blue: 0.98)
private let lime = Color(red: 0.72, green: 0.88, blue: 0.56)

private struct StatusTile<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(18)
            .background {
                ZStack {
                    StrataColor.panel
                    LinearGradient(colors: [tint.opacity(0.075), tint.opacity(0.018), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StrataColor.border))
    }
}

private func tileLabel(_ text: String, icon: String, color: Color) -> some View {
    Label {
        Text(text).foregroundStyle(StrataColor.ink)
    } icon: {
        Image(systemName: icon).foregroundStyle(color)
    }
    .font(.system(size: 14, weight: .semibold))
}

private func metricValue(_ value: String, unit: String = "") -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(value).font(.system(size: 36, weight: .medium, design: .rounded))
        if !unit.isEmpty { Text(unit).font(.system(size: 18, weight: .medium)).foregroundStyle(StrataColor.muted) }
    }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.62)
}

private struct MetricTrace: View {
    @Environment(\.locale) private var locale
    let points: [ResourceTrend.Point]
    let color: Color
    var bars = false
    var body: some View {
        let _ = locale
        if bars {
            Canvas { context, area in
                let barWidth = max(1, area.width / 31 * 0.72)
                let plotWidth = max(0, area.width - barWidth)
                for point in points {
                    let x = (1 + point.offset / ResourceTrend.duration) * plotWidth
                    let height = max(1, point.percent / 100 * area.height)
                    let bar = CGRect(x: x, y: area.height - height, width: barWidth, height: height)
                    let path = Path(roundedRect: bar, cornerRadius: min(2, barWidth / 3))
                    context.fill(path, with: .linearGradient(Gradient(colors: [color, color.opacity(0.38)]),
                        startPoint: CGPoint(x: x, y: bar.minY), endPoint: CGPoint(x: x, y: bar.maxY)))
                }
                context.fill(Path(CGRect(x: 0, y: area.height - 1, width: area.width, height: 1)),
                             with: .color(color.opacity(0.16)))
            }.accessibilityLabel(tr("过去 60 秒的 CPU 使用率", "CPU usage over the last 60 seconds"))
        } else {
            Chart(points) { point in
                LineMark(x: .value(tr("采样时间", "Time"), point.offset), y: .value(tr("使用率", "Usage"), point.percent),
                         series: .value(tr("采样段", "Sample segment"), point.segment))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                PointMark(x: .value(tr("采样时间", "Time"), point.offset), y: .value(tr("使用率", "Usage"), point.percent))
                    .foregroundStyle(color).symbolSize(7).accessibilityHidden(true)
            }
            .chartXScale(domain: -ResourceTrend.duration...0)
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartPlotStyle { plot in
                plot.background(alignment: .bottom) { Rectangle().fill(color.opacity(0.16)).frame(height: 1) }
            }
            .accessibilityLabel(tr("过去 60 秒的内存使用率", "Memory usage over the last 60 seconds"))
        }
    }
}

private func memorySize(_ bytes: UInt64) -> String {
    let gibibytes = Double(bytes) / 1_073_741_824
    return gibibytes.formatted(.number.locale(AppLanguage.current.locale).precision(.fractionLength(0...1))) + " GiB"
}

// A vector illustration of a silicon package. Its traces are artwork; live metrics sit outside it.
private struct ChipArtwork: View {
    var body: some View {
        Canvas { ctx, size in
            let unit = min(size.width / 178, size.height / 130)
            ctx.translateBy(x: size.width * 0.52, y: size.height * 0.48)
            ctx.scaleBy(x: unit, y: unit)
            func point(_ x: Double, _ y: Double, lift: Double = 0) -> CGPoint {
                CGPoint(x: x * 0.93 - y * 0.63, y: x * 0.21 + y * 0.66 + lift)
            }
            func shape(_ pts: [CGPoint]) -> Path {
                var path = Path()
                path.addLines(pts)
                path.closeSubpath()
                return path
            }
            func plate(_ x: Double, _ y: Double, _ w: Double, _ h: Double, lift: Double = 0) -> Path {
                shape([point(x, y, lift: lift), point(x + w, y, lift: lift),
                       point(x + w, y + h, lift: lift), point(x, y + h, lift: lift)])
            }
            for position in stride(from: -32.0, through: 32, by: 4) {
                for sign in [-1.0, 1.0] {
                    let end = 62 + abs(position) / 3
                    var pins = Path()
                    pins.move(to: point(position, sign * 37))
                    pins.addLine(to: point(position, sign * end))
                    pins.move(to: point(sign * 37, position))
                    pins.addLine(to: point(sign * end, position))
                    ctx.stroke(pins, with: .color(jade.opacity(0.24)), lineWidth: 1.1)
                }
            }
            for depth in stride(from: 6, through: 0, by: -1) {
                let body = plate(-39, -39, 78, 78, lift: Double(depth))
                let fill = depth == 0 ? Color(red: 0.20, green: 0.37, blue: 0.36) : Color(red: 0.10, green: 0.22, blue: 0.20)
                ctx.fill(body, with: .color(fill))
            }
            ctx.stroke(plate(-39, -39, 78, 78), with: .color(jade.opacity(0.68)), lineWidth: 1.0)
            ctx.fill(plate(-34, -34, 68, 68), with: .color(Color(red: 0.075, green: 0.15, blue: 0.17)))
            for row in 0..<4 {
                for column in 0..<4 {
                    let block = plate(-27 + Double(column) * 14, -27 + Double(row) * 14, 11.5, 11.5)
                    let brightness = 0.20 + Double((row * 3 + column * 7) % 8) * 0.055
                    ctx.fill(block, with: .color(jade.opacity(brightness)))
                    ctx.stroke(block, with: .color(jade.opacity(0.35)), lineWidth: 0.6)
                }
            }
        }.accessibilityHidden(true)
    }
}

struct StatusBoard: View {
    @Environment(\.locale) private var locale
    let readings: StatusReadings
    private let gap: CGFloat = 12

    var body: some View {
        let _ = locale
        GeometryReader { canvas in
            ScrollView { dashboard(size: canvas.size) }
        }
    }

    func dashboard(size: CGSize) -> some View {
        let compact = size.width < 865
        let inset: CGFloat = compact ? 18 : 25
        let width = min(1260, max(1, size.width - inset * 2))
        let leading = floor((width - gap * 2) * 0.40)
        let right = width - leading - gap
        let tile = max(1, (right - gap) / 2)
        let height = max(366, min(468, size.height - 118))
        return VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("系统状态", "System status")).font(.system(size: 30, weight: .semibold))
                Spacer()
                if let latest = readings.trend.samples.last {
                    Text(tr("采样于 ", "Updated ") + latest.date.formatted(.dateTime.locale(locale).hour().minute().second()))
                        .font(.caption.monospacedDigit()).foregroundStyle(StrataColor.muted)
                }
            }
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: gap) {
                    hardware(compact: compact).frame(height: height * 0.63)
                    network.frame(height: height * 0.37 - gap)
                }.frame(width: leading)
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        usageCard(memory: false).frame(width: tile)
                        usageCard(memory: true).frame(width: tile)
                    }.frame(height: height * 0.54)
                    HStack(spacing: gap) {
                        storage.frame(width: max(1, right * 0.55 - gap / 2))
                        power
                    }.frame(height: height * 0.46 - gap)
                }.frame(width: right)
            }
        }.frame(width: width).padding(.horizontal, inset).padding(.vertical, 21)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func hardware(compact: Bool) -> some View {
        StatusTile(tint: jade) {
            VStack(alignment: .leading, spacing: 4) {
                tileLabel(tr("本机概览", "This Mac"), icon: "desktopcomputer", color: jade)
                Spacer(minLength: 6)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(readings.chip).font(.system(size: compact ? 24 : 30, weight: .semibold, design: .rounded))
                            .lineLimit(2).minimumScaleFactor(0.6).foregroundStyle(StrataColor.ink)
                        Text(tr("\(ProcessInfo.processInfo.activeProcessorCount) 核 CPU", "\(ProcessInfo.processInfo.activeProcessorCount)-core CPU"))
                        Text(memorySize(ProcessInfo.processInfo.physicalMemory) + tr(" 内存", " memory"))
                    }.font(.system(size: 12)).foregroundStyle(StrataColor.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ChipArtwork().frame(width: compact ? 109 : 157, height: compact ? 96 : 121)
                }
                Spacer(minLength: 6)
                Divider()
                HStack {
                    Text(tr("热状态", "Thermal state")).foregroundStyle(StrataColor.muted)
                    Spacer()
                    Text(thermalDescription).fontWeight(.medium).foregroundStyle(thermalColor)
                }.font(.caption).padding(.top, 4)
                HStack {
                    Text(tr("连续运行", "Uptime")).foregroundStyle(StrataColor.muted)
                    Spacer(); Text(uptimeDescription)
                }.font(.caption)
            }
        }
    }

    private var thermalDescription: String {
        switch readings.thermal {
        case .nominal: return tr("正常", "Normal")
        case .fair: return tr("轻度升温", "Warm")
        case .serious: return tr("较高", "High")
        case .critical: return tr("过热", "Critical")
        default: return tr("未知", "Unknown")
        }
    }

    private var thermalColor: Color {
        switch readings.thermal {
        case .nominal: return jade
        case .fair, .serious: return amber
        case .critical: return .orange
        default: return StrataColor.muted
        }
    }

    private var uptimeDescription: String {
        guard let uptime = readings.uptime else { return "—" }
        let minutes = Int(uptime / 60)
        if minutes >= 1440 { return tr("\(minutes / 1440) 天 \(minutes / 60 % 24) 小时", "\(minutes / 1440)d \(minutes / 60 % 24)h") }
        if minutes >= 60 { return tr("\(minutes / 60) 小时 \(minutes % 60) 分", "\(minutes / 60)h \(minutes % 60)m") }
        return tr("\(minutes) 分钟", "\(minutes) min")
    }

    private func usageCard(memory: Bool) -> some View {
        let color = memory ? lilac : amber
        let fraction = memory ? readings.memory?.fraction : readings.cpu
        return StatusTile(tint: color) {
            VStack(alignment: .leading, spacing: 7) {
                tileLabel(memory ? tr("内存", "Memory") : "CPU", icon: memory ? "memorychip" : "cpu", color: color)
                Spacer(minLength: 0)
                if let fraction {
                    metricValue(String(Int((fraction * 100).rounded())), unit: "%")
                } else {
                    Text(readings.warmingUp && !memory ? tr("采样中…", "Sampling…") : tr("无法读取", "Unavailable")).font(.title3)
                }
                MetricTrace(points: readings.trend.points(for: memory ? \.memory : \.cpu), color: color, bars: !memory)
                    .frame(maxHeight: 60)
                HStack {
                    Text(tr("60 秒前", "60s ago")); Spacer(); Text(tr("现在", "Now"))
                }.font(.system(size: 10)).foregroundStyle(StrataColor.muted)
                Spacer(minLength: 0)
                if memory, let reading = readings.memory {
                    Text(memorySize(reading.used) + " / " + memorySize(reading.total))
                        .font(.caption).lineLimit(1).minimumScaleFactor(0.75)
                } else {
                    Text(memory ? tr("已用内存", "Used memory") : tr("全机使用率", "System-wide usage")).font(.caption)
                }
            }
        }
    }

    private var network: some View {
        StatusTile(tint: sky) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    tileLabel(tr("网络速率", "Network"), icon: "network", color: sky)
                    Spacer()
                    Text(readings.link ?? tr("主接口不可用", "No active interface")).font(.caption).foregroundStyle(StrataColor.muted)
                }
                Spacer(minLength: 4)
                HStack(spacing: 10) {
                    speed(tr("下载", "Download"), icon: "arrow.down", rate: readings.throughput?.down)
                    Divider()
                    speed(tr("上传", "Upload"), icon: "arrow.up", rate: readings.throughput?.up)
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func speed(_ title: String, icon: String, rate: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(sky)
            let bytes = rate.map { Int64(clamping: UInt64(min(Double(Int64.max / 2), $0))) }
            let formatted = bytes.map { $0 < 1000 ? String($0) + " B" : storageSize($0) }
            Text(formatted.map { $0 + "/s" } ?? "—")
                .font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.68)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var storage: some View {
        StatusTile(tint: amber) {
            VStack(alignment: .leading, spacing: 9) {
                tileLabel(tr("启动磁盘", "Startup disk"), icon: "internaldrive", color: amber)
                Spacer(minLength: 2)
                if let disk = readings.disk {
                    metricValue(storageSize(Int64(clamping: disk.total - disk.used)))
                    Text(tr("可用空间", "Available")).font(.caption).foregroundStyle(StrataColor.muted)
                    Spacer(minLength: 2)
                    GeometryReader { area in
                        Capsule().fill(amber.opacity(0.13)).overlay(alignment: .leading) {
                            Capsule().fill(amber).frame(width: area.size.width * disk.fraction)
                        }
                    }.frame(height: 6)
                    Text(tr("已用 ", "Used ") + storageSize(Int64(clamping: disk.used)) + " / " + storageSize(Int64(clamping: disk.total)))
                        .font(.caption).lineLimit(1).minimumScaleFactor(0.75)
                } else { Text(tr("容量不可用", "Capacity unavailable")).foregroundStyle(StrataColor.muted) }
            }
        }
    }

    private var power: some View {
        StatusTile(tint: lime) {
            VStack(alignment: .leading, spacing: 7) {
                tileLabel(tr("电池", "Battery"), icon: "battery.75", color: lime)
                Spacer(minLength: 2)
                if let charge = readings.battery.charge {
                    metricValue(String(Int((charge * 100).rounded())), unit: "%")
                    GeometryReader { area in
                        HStack(spacing: 2) {
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 5).strokeBorder(lime.opacity(0.63), lineWidth: 1.5)
                                GeometryReader { inner in
                                    RoundedRectangle(cornerRadius: 2.5).fill(lime)
                                        .frame(width: inner.size.width * charge)
                                }.padding(3)
                            }
                            Capsule().fill(lime.opacity(0.65)).frame(width: 3, height: 8)
                        }.frame(width: min(100, area.size.width), height: 19)
                    }.frame(height: 20).accessibilityHidden(true)
                } else {
                    metricValue("—")
                }
                Spacer(minLength: 2)
                Text(readings.battery.supply.description).font(.caption).foregroundStyle(StrataColor.muted)
            }
        }
    }
}

struct SystemPage: View {
    @Environment(\.scenePhase) private var phase
    @State private var readings = StatusReadings()

    var body: some View {
        StatusBoard(readings: readings)
            .task(id: phase) {
                guard phase == .active else { return }
                var next = StatusReadings()
                while !Task.isCancelled {
                    next.sample()
                    readings = next
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                }
            }
    }
}
