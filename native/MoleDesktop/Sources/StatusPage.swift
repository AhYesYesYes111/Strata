import AppKit
import Darwin
import IOKit.ps
import SwiftUI
import SystemConfiguration

struct ProcessorSample {
    let ticks: (UInt32, UInt32, UInt32, UInt32)

    static func readCores() -> [Self]? {
        var processors: natural_t = 0
        var buffer: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processors, &buffer, &count) == KERN_SUCCESS,
              let buffer else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: buffer)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let stride = Int(CPU_STATE_MAX)
        guard processors > 0, Int(count) >= Int(processors) * stride else { return nil }
        return (0..<Int(processors)).map { index in
            let base = buffer.advanced(by: index * stride)
            return Self(ticks: (UInt32(bitPattern: base[Int(CPU_STATE_USER)]),
                                UInt32(bitPattern: base[Int(CPU_STATE_SYSTEM)]),
                                UInt32(bitPattern: base[Int(CPU_STATE_IDLE)]),
                                UInt32(bitPattern: base[Int(CPU_STATE_NICE)])))
        }
    }

    func delta(since prev: Self) -> (busy: UInt64, total: UInt64) {
        let busy = UInt64(ticks.0 &- prev.ticks.0) + UInt64(ticks.1 &- prev.ticks.1) + UInt64(ticks.3 &- prev.ticks.3)
        let total = busy + UInt64(ticks.2 &- prev.ticks.2)
        return (busy, total)
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
        guard let volume = VolumeReading.read() else { return nil }
        return Self(used: UInt64(volume.used), total: UInt64(volume.capacity))
    }
}

struct ResourceSample {
    let date: Date
    let cpu: Double?
    let memory: Double?
    var gpu: Double?
    var down: Double?
    var up: Double?
    var interface: String?
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

    func points(for metric: KeyPath<ResourceSample, Double?>, upperBound: Double = 1, sameLink: Bool = false) -> [Point] {
        guard let latest = samples.last, upperBound.isFinite, upperBound > 0 else { return [] }
        var points: [Point] = []
        var previous: Date?
        var segment = 0
        let relevant = sameLink ? samples.suffix(from: samples.lastIndex(where: { $0.interface != latest.interface }).map { $0 + 1 } ?? 0) : samples[...]
        for sample in relevant {
            guard let value = sample[keyPath: metric], value.isFinite, value >= 0 else {
                previous = nil
                continue
            }
            if previous.map({ sample.date.timeIntervalSince($0) > Self.longestInterval }) ?? true {
                segment += 1
            }
            points.append(Point(date: sample.date, offset: sample.date.timeIntervalSince(latest.date),
                                percent: min(value / upperBound, 1) * 100, segment: segment))
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
    private var cores: [ProcessorSample]?
    private var lastCapacity: Date?
    private(set) var usageByCore: [Double?] = []
    private(set) var sensors = HardwareTelemetry()
    private(set) var diskIO: (read: Double, write: Double)?
    private(set) var gpuWatts: Double?
    private(set) var vitals = SystemVitals()
    private(set) var linkType: String?
    private(set) var signalDBm: Int?
    var health: ResourceHealth? {
        ResourceHealth.evaluate(cpu: cpu, memory: memory?.fraction, disk: disk?.fraction, pressure: vitals.pressure,
                                temperature: sensors.cpuCelsius, ioBytesPerSecond: diskIO.map { $0.read + $0.write },
                                batteryHealth: sensors.batteryHealthPercent, thermal: thermal)
    }
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
        let current = ProcessorSample.readCores()
        cpu = nil
        usageByCore = []
        if continuous, let current, let cores, current.count == cores.count {
            let deltas = zip(current, cores).map { $0.delta(since: $1) }
            let total = deltas.reduce(UInt64(0)) { $0 + $1.total }
            if total > 0 { cpu = Double(deltas.reduce(UInt64(0)) { $0 + $1.busy }) / Double(total) }
            usageByCore = deltas.map { $0.total == 0 ? nil : Double($0.busy) / Double($0.total) }
        }
        warmingUp = current != nil && cpu == nil
        cores = current
        let hardware = HardwareTelemetry.read()
        diskIO = continuous ? hardware.diskRates(since: sensors) : nil
        gpuWatts = continuous ? hardware.gpuPower(since: sensors) : nil
        sensors = hardware
        vitals = SystemVitals.read()
        let counters = LinkCounters.read(from: networkStore)
        throughput = counters?.rate(since: linkCounter, seconds: elapsed)
        if link != counters?.name {
            linkType = counters.flatMap { item in
                let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
                guard let match = interfaces.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == item.name }) else { return nil }
                let kind = SCNetworkInterfaceGetInterfaceType(match) as String?
                if kind == kSCNetworkInterfaceTypeIEEE80211 as String { return "Wi-Fi" }
                if kind == kSCNetworkInterfaceTypeEthernet as String { return "Ethernet" }
                return nil
            }
        }
        link = counters?.name
        signalDBm = linkType == "Wi-Fi" ? LinkQuality.signalDBm(interface: link) : nil
        linkCounter = counters
        memory = CapacitySample.memory()
        if lastCapacity.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            disk = CapacitySample.disk()
            lastCapacity = now
        }
        battery = BatteryReading.read()
        var boot = timeval()
        var bootBytes = MemoryLayout.size(ofValue: boot)
        if sysctlbyname("kern.boottime", &boot, &bootBytes, nil, 0) == 0, boot.tv_sec > 0 {
            uptime = max(0, now.timeIntervalSince1970 - Double(boot.tv_sec))
        } else {
            uptime = nil
        }
        thermal = ProcessInfo.processInfo.thermalState
        trend.append(ResourceSample(date: now, cpu: cpu, memory: memory?.fraction,
                                    gpu: sensors.gpuPercent.map { $0 / 100 }, down: throughput?.down, up: throughput?.up, interface: link))
    }
}

private let jade = Color(red: 0.51, green: 0.88, blue: 0.76)
private let lilac = Color(red: 0.77, green: 0.73, blue: 0.99)
private let amber = Color(red: 0.97, green: 0.78, blue: 0.50)
private let sky = Color(red: 0.55, green: 0.78, blue: 0.98)
private let lime = Color(red: 0.72, green: 0.88, blue: 0.56)

private struct StatusTile<Content: View>: View {
    @Environment(\.statusCardHeight) private var height
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(13)
            .frame(height: height)
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
        Text(value).font(.system(size: 30, weight: .semibold, design: .rounded))
        if !unit.isEmpty { Text(unit).font(.system(size: 15, weight: .medium)).foregroundStyle(StrataColor.muted) }
    }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.62)
}

private struct MetricTrace: View {
    let points: [ResourceTrend.Point]
    let color: Color
    var baseline = true

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var segment: Int?
            for point in points {
                let p = CGPoint(x: (1 + point.offset / ResourceTrend.duration) * (size.width - 2) + 1,
                                y: (1 - point.percent / 100) * (size.height - 3) + 1.5)
                if segment == point.segment { path.addLine(to: p) }
                else {
                    path.move(to: p)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)), with: .color(color))
                }
                segment = point.segment
            }
            if baseline {
                context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(color.opacity(0.18)))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
        }.accessibilityHidden(true)
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
    @State private var topPower: String?
    @State private var showCores = true

    var body: some View {
        GeometryReader { canvas in
            ScrollView { dashboard(size: canvas.size) }
        }
    }

    func dashboard(size: CGSize) -> some View {
        let _ = locale
        let narrow = size.width < 880
        let inset: CGFloat = narrow ? 16 : 20
        let width = min(1440, max(1, size.width - inset * 2))
        let gap: CGFloat = 9
        let height: CGFloat = size.width > 1130 ? 151 : 139
        let unit = (width - gap * 3) / 4.32
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("系统状态", "System status")).font(.system(size: 23, weight: .semibold))
                Spacer()
                if let latest = readings.trend.samples.last {
                    Text(tr("更新于 ", "Updated ") + latest.date.formatted(.dateTime.locale(locale).hour().minute().second()))
                        .font(.caption.monospacedDigit()).foregroundStyle(StrataColor.muted)
                }
            }
            if narrow {
                Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                    GridRow { overview; usage(.cpu) }
                    GridRow { usage(.gpu); usage(.memory) }
                    GridRow { battery; storage }
                    GridRow { network; fan }
                }
            } else {
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        overview.frame(width: unit * 1.32); usage(.cpu); usage(.gpu); usage(.memory)
                    }
                    HStack(spacing: gap) {
                        battery.frame(width: unit * 1.32); storage; network; fan
                    }
                }
            }
            ProcessMonitorView { topPower = $0 }
        }
        .environment(\.statusCardHeight, height)
        .frame(width: width).padding(.horizontal, inset).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .regular)).foregroundStyle(StrataColor.muted)
            .lineLimit(1).minimumScaleFactor(0.81).help(text)
    }

    private func headline(_ title: String, _ icon: String, color: Color, badge: String? = nil) -> some View {
        HStack(spacing: 4) {
            tileLabel(title, icon: icon, color: color).lineLimit(1)
            Spacer(minLength: 2)
            if let badge {
                Text(badge).font(.system(size: 10, weight: .medium)).foregroundStyle(StrataColor.muted)
                    .lineLimit(1).minimumScaleFactor(0.78)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private var overview: some View {
        StatusTile(tint: jade) {
            VStack(alignment: .leading, spacing: 4) {
                headline(tr("健康", "Health"), "sun.max", color: jade, badge: readings.chip)
                Spacer(minLength: 1)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        metricValue(readings.health.map { String($0.score) } ?? "—", unit: readings.health?.label ?? "")
                        caption(readings.health?.cause.label ?? tr("正在采样…", "Sampling…"))
                    }
                    Spacer(minLength: 0)
                    ChipArtwork().frame(width: 61, height: 47)
                }
                Spacer(minLength: 1)
                caption(tr("运行 ", "Up ") + uptimeDescription + " · " + thermalDescription)
            }
        }.help(tr("根据 CPU、内存、磁盘和可用传感器估算，满分 100。", "Resource score out of 100, based on CPU, memory, storage and available sensors."))
    }

    private var thermalDescription: String {
        switch readings.thermal {
        case .nominal: return tr("热状态正常", "Thermals normal")
        case .fair: return tr("轻度升温", "Warm")
        case .serious: return tr("热压力较高", "High thermal pressure")
        case .critical: return tr("热压力严重", "Critical thermal pressure")
        default: return tr("热状态未知", "Thermals unknown")
        }
    }

    private var uptimeDescription: String {
        guard let uptime = readings.uptime else { return "—" }
        let minutes = Int(uptime / 60)
        if minutes >= 1440 { return tr("\(minutes / 1440) 天 \(minutes / 60 % 24) 小时", "\(minutes / 1440)d \(minutes / 60 % 24)h") }
        if minutes >= 60 { return tr("\(minutes / 60) 小时 \(minutes % 60) 分", "\(minutes / 60)h \(minutes % 60)m") }
        return tr("\(minutes) 分钟", "\(minutes) min")
    }

    private enum Usage { case cpu, gpu, memory }

    private func usage(_ kind: Usage) -> some View {
        let sensor = readings.sensors
        let title = kind == .cpu ? "CPU" : kind == .gpu ? "GPU" : tr("内存", "Memory")
        let color = kind == .cpu ? jade : kind == .gpu ? amber : lilac
        let key: KeyPath<ResourceSample, Double?> = kind == .cpu ? \.cpu : kind == .gpu ? \.gpu : \.memory
        let fraction = readings.trend.samples.last?[keyPath: key]
        let temperature = kind == .cpu ? sensor.cpuCelsius : sensor.gpuCelsius
        let badge = kind == .memory ? readings.vitals.pressure?.label : temperature.map { "\(Int($0.rounded()))°C" }
        let points = readings.trend.points(for: key)
        return StatusTile(tint: color) {
            VStack(alignment: .leading, spacing: 4) {
                headline(title, kind == .cpu ? "cpu" : kind == .gpu ? "display" : "memorychip", color: color, badge: badge)
                Spacer(minLength: 1)
                metricValue(fraction.map { String(Int(($0 * 100).rounded())) } ?? "—", unit: fraction == nil ? "" : "%")
                if kind == .cpu {
                    Button { showCores.toggle() } label: {
                        Group {
                            if showCores {
                                HStack(alignment: .bottom, spacing: 3) {
                                    ForEach(readings.usageByCore.indices, id: \.self) { i in
                                        if let fraction = readings.usageByCore[i] {
                                            RoundedRectangle(cornerRadius: 1.5).fill(color.gradient)
                                                .frame(height: max(1, 21 * fraction))
                                        } else { Color.clear.frame(height: 1) }
                                    }
                                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            } else { MetricTrace(points: points, color: color) }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).frame(height: 22)
                    .help(showCores ? tr("每条代表一个核心。点按查看 60 秒趋势。", "Each bar is one core. Click for the 60-second trend.") : tr("点按查看各核心使用率", "Click to show usage by core"))
                    .accessibilityLabel(tr("切换核心读数和 CPU 历史", "Switch between CPU cores and history"))
                } else { MetricTrace(points: points, color: color).frame(height: 22) }
                Spacer(minLength: 1)
                caption(usageDetail(kind))
            }
        }
    }

    private func usageDetail(_ kind: Usage) -> String {
        switch kind {
        case .cpu:
            let cores = ProcessInfo.processInfo.activeProcessorCount
            let load = readings.vitals.load.map { $0.formatted(.number.locale(locale).precision(.fractionLength(1))) }
            return tr("\(cores) 核", "\(cores) cores") + (load.map { tr(" · 负载 ", " · Load avg ") + $0 } ?? "")
        case .gpu:
            guard let percent = readings.sensors.gpuPercent else { return tr("系统未提供 GPU 使用率", "GPU usage unavailable") }
            let load = percent < 10 ? tr("空闲", "Idle") : percent < 80 ? tr("运行中", "Active") : tr("高负载", "High load")
            return load + (readings.sensors.gpuCores.map { tr(" · \($0) 核", " · \($0) cores") } ?? "")
                + (readings.gpuWatts.map { String(format: " · %.1f W", $0) } ?? "")
        case .memory:
            return (readings.memory.map { memorySize($0.used) + " / " + memorySize($0.total) } ?? "—")
                + (readings.vitals.swap.map { tr(" · 交换 ", " · Swap ") + memorySize($0) } ?? "")
        }
    }

    private var battery: some View {
        let s = readings.sensors
        let watts = s.batteryWatts.map { String(format: "%.1f W", abs($0)) }
        let minutes = s.batteryMinutes.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
        let time = minutes.map { readings.battery.supply == .charging ? tr("\($0) 后充满", "\($0) to full") : tr("剩余 \($0)", "\($0) left") }
        return StatusTile(tint: lime) {
            VStack(alignment: .leading, spacing: 4) {
                headline(tr("电池", "Battery"), "battery.75", color: lime, badge: s.batteryHealthPercent.map { tr("健康 \(Int($0))%", "\(Int($0))% health") })
                Spacer(minLength: 1)
                HStack(alignment: .firstTextBaseline) {
                    metricValue(readings.battery.charge.map { String(Int(($0 * 100).rounded())) } ?? "—", unit: readings.battery.charge == nil ? "" : "%")
                    Spacer(minLength: 1)
                    if let cycles = s.batteryCycles { caption(tr("\(cycles) 次循环", "\(cycles) cycles")) }
                }
                caption(([readings.battery.supply.description] + [watts, time].compactMap { $0 }).joined(separator: " · "))
                Spacer(minLength: 0)
                if let topPower { caption(tr("CPU 能耗最高 · ", "Top CPU power · ") + topPower) }
                else if let power = s.adapterWatts { caption(tr("适配器 ", "Adapter ") + "\(Int(power)) W") }
            }
        }
    }

    private func gauge(_ value: Double?, _ tint: Color) -> some View {
        GeometryReader { rect in
            Capsule().fill(tint.opacity(0.12)).overlay(alignment: .leading) {
                if let value { Capsule().fill(tint).frame(width: rect.size.width * min(1, max(0, value))) }
            }
        }.frame(height: 5)
    }

    private var storage: some View {
        let disk = readings.disk
        return StatusTile(tint: amber) {
            VStack(alignment: .leading, spacing: 4) {
                headline(tr("可用空间", "Free space"), "internaldrive", color: amber, badge: disk.map { storageSize(Int64(clamping: $0.total)) })
                Spacer(minLength: 1)
                metricValue(disk.map { storageSize(Int64(clamping: $0.total - $0.used)) } ?? "—")
                gauge(disk?.fraction, amber)
                if let disk { caption(tr("已用 ", "Used ") + storageSize(Int64(clamping: disk.used)) + " · \(Int((disk.fraction * 100).rounded()))%") }
                Spacer(minLength: 0)
                if let rates = readings.diskIO { caption(tr("读 ", "R ") + rate(rates.read) + tr(" · 写 ", " · W ") + rate(rates.write)) }
            }
        }
    }

    private func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let bytes = Int64(min(Double(Int64.max / 2), value))
        return (bytes < 1000 ? "\(bytes) B" : storageSize(bytes)) + "/s"
    }

    private var network: some View {
        let history = readings.trend
        let peak = max(1, history.samples.filter { $0.interface == readings.link }.reduce(0.0) { max($0, $1.down ?? 0, $1.up ?? 0) })
        return StatusTile(tint: sky) {
            VStack(alignment: .leading, spacing: 4) {
                headline(tr("网络", "Network"), "network", color: sky, badge: readings.linkType ?? readings.link)
                Spacer(minLength: 1)
                metricValue(rate(readings.throughput?.down))
                ZStack {
                    MetricTrace(points: history.points(for: \.down, upperBound: peak, sameLink: true), color: sky)
                    MetricTrace(points: history.points(for: \.up, upperBound: peak, sameLink: true), color: jade, baseline: false)
                }.frame(height: 21)
                Spacer(minLength: 0)
                caption(tr("↑ 上传 ", "↑ Upload ") + rate(readings.throughput?.up)
                        + (readings.signalDBm.map { " · \($0) dBm" } ?? readings.link.map { " · " + $0 } ?? ""))
            }
        }.accessibilityHint(tr("大号读数为下载速率，曲线显示最近一分钟的双向流量。", "The main reading is download speed. The traces show both directions over the last minute."))
    }

    private var fan: some View {
        let s = readings.sensors
        return StatusTile(tint: amber) {
            VStack(alignment: .leading, spacing: 4) {
                headline(tr("风扇", "Fan"), "fanblades", color: amber, badge: s.fanPercent.map { tr("转速 \(Int($0.rounded()))%", "\(Int($0.rounded()))% of max") })
                Spacer(minLength: 1)
                metricValue(s.fanRPM.map { Int($0.rounded()).formatted(.number.locale(locale)) } ?? "—", unit: s.fanRPM == nil ? "" : "RPM")
                gauge(s.fanPercent.map { $0 / 100 }, amber)
                Spacer(minLength: 0)
                if let count = s.fanCount, count > 0, s.fanRPM != nil {
                    let mode = s.fanAutomatic.map { $0 ? tr("自动调速", "Automatic") : tr("手动调速", "Manual") }
                    caption(tr("\(count) 个风扇", count == 1 ? "1 fan" : "\(count) fans") + " · " + (mode ?? tr("实测转速", "Measured speed")))
                } else {
                    caption(s.fanCount == 0 ? tr("本机无内置风扇", "Fanless Mac") : tr("转速传感器不可用", "RPM sensor unavailable"))
                }
            }
        }
    }
}

private struct CardHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 139 }
private extension EnvironmentValues {
    var statusCardHeight: CGFloat {
        get { self[CardHeightKey.self] }
        set { self[CardHeightKey.self] = newValue }
    }
}

private actor StatusSampler {
    var readings = StatusReadings()
    func next() -> StatusReadings {
        readings.sample()
        return readings
    }
}

struct SystemPage: View {
    @Environment(\.scenePhase) private var phase
    @State private var readings = StatusReadings()

    var body: some View {
        StatusBoard(readings: readings)
            .task(id: phase) {
                guard phase == .active else { return }
                let sampler = StatusSampler()
                while !Task.isCancelled {
                    let sample = await sampler.next()
                    guard !Task.isCancelled else { return }
                    readings = sample
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                }
            }
    }
}
