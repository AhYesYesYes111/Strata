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
    private var leading: [ResourceSample] = []

    mutating func append(_ sample: ResourceSample) {
        if let last = samples.last, last.date >= sample.date {
            samples.removeAll(keepingCapacity: true)
            leading.removeAll(keepingCapacity: true)
        }
        leading += samples.prefix { sample.date.timeIntervalSince($0.date) > Self.duration }
        leading.removeAll { sample.date.timeIntervalSince($0.date) > Self.duration + 2 * Self.longestInterval }
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

    var playbackInterval: TimeInterval? {
        guard samples.count >= 2 else { return nil }
        let step = samples[samples.count - 1].date.timeIntervalSince(samples[samples.count - 2].date)
        return step > 0 && step <= Self.longestInterval ? step : nil
    }

    func points(for metric: KeyPath<ResourceSample, Double?>, upperBound: Double = 1, sameLink: Bool = false,
                includeLeading: Bool = false) -> [Point] {
        guard let latest = samples.last, upperBound.isFinite, upperBound > 0 else { return [] }
        var points: [Point] = []
        var previous: Date?
        var segment = 0
        let window = includeLeading ? leading + samples : samples
        let relevant = sameLink ? window.suffix(from: window.lastIndex(where: { $0.interface != latest.interface }).map { $0 + 1 } ?? 0) : window[...]
        for sample in relevant {
            guard let value = sample[keyPath: metric], value.isFinite, value >= 0 else {
                previous = nil
                continue
            }
            if previous.map({ sample.date.timeIntervalSince($0) > Self.longestInterval }) ?? true {
                segment += 1
            }
            let fraction = value / upperBound
            points.append(Point(date: sample.date, offset: sample.date.timeIntervalSince(latest.date),
                                percent: (includeLeading && sameLink ? fraction : min(fraction, 1)) * 100, segment: segment))
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
    private(set) var chip = "Mac"
    private lazy var networkStore = SCDynamicStoreCreate(nil, "Strata Status" as CFString, nil, nil)
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

    init(history: ResourceTrend = ResourceTrend()) {
        trend = history
    }

    mutating func sample() {
        let now = Date()
        if lastCapacity == nil { chip = chipName() }
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

let jade = Color(red: 0.51, green: 0.88, blue: 0.76)
let lilac = Color(red: 0.77, green: 0.73, blue: 0.99)
let amber = Color(red: 0.97, green: 0.78, blue: 0.50)
let sky = Color(red: 0.55, green: 0.78, blue: 0.98)
let lime = Color(red: 0.72, green: 0.88, blue: 0.56)

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

struct MetricTrace: View {
    let points: [ResourceTrend.Point]
    let color: Color
    var baseline = true
    var sampleTime: Date?
    var interval: TimeInterval?
    var upperBound: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase

    var body: some View {
        let end = sampleTime?.timeIntervalSinceReferenceDate
        let canvas = TraceCanvas(points: points, color: color, baseline: baseline, sampleEnd: end,
                                 windowEnd: end ?? 0, targetBound: upperBound, displayedBound: upperBound)
        if !reduceMotion, phase == .active, let interval {
            canvas.animation(.linear(duration: interval), value: end)
        } else {
            canvas
        }
    }
}

struct TraceCanvas: View, Animatable {
    let points: [ResourceTrend.Point]
    let color: Color
    let baseline: Bool
    let sampleEnd: TimeInterval?
    var windowEnd: TimeInterval
    let targetBound: Double
    var displayedBound: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(windowEnd, displayedBound) }
        set { windowEnd = newValue.first; displayedBound = newValue.second }
    }

    func position(of point: ResourceTrend.Point, in size: CGSize) -> CGPoint {
        let lag = (sampleEnd ?? windowEnd) - windowEnd
        let fraction = point.percent / 100 * targetBound / displayedBound
        return CGPoint(x: (1 + (point.offset + lag) / ResourceTrend.duration) * (size.width - 2) + 1,
                       y: (1 - fraction) * (size.height - 3) + 1.5)
    }

    var body: some View {
        Canvas { context, size in
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            var path = Path()
            var segment: Int?
            for point in points {
                let p = position(of: point, in: size)
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

func statusUptime(_ uptime: TimeInterval?) -> String {
    guard let uptime else { return "—" }
    let minutes = Int(uptime / 60)
    if minutes >= 1440 { return tr("\(minutes / 1440) 天 \(minutes / 60 % 24) 小时", "\(minutes / 1440)d \(minutes / 60 % 24)h") }
    if minutes >= 60 { return tr("\(minutes / 60) 小时 \(minutes % 60) 分", "\(minutes / 60)h \(minutes % 60)m") }
    return tr("\(minutes) 分钟", "\(minutes) min")
}

func statusRate(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    let bytes = Int64(min(Double(Int64.max / 2), value))
    return (bytes < 1000 ? "\(bytes) B" : storageSize(bytes)) + "/s"
}

func memorySize(_ bytes: UInt64) -> String {
    let gibibytes = Double(bytes) / 1_073_741_824
    return gibibytes.formatted(.number.locale(AppLanguage.current.locale).precision(.fractionLength(0...1))) + " GiB"
}

struct StatusBoard: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let readings: StatusReadings
    var processes: [ProcessReading] = []
    var didSampleProcesses = false
    private var topPower: String? {
        processes.max { ($0.watts ?? 0) < ($1.watts ?? 0) }.flatMap { ($0.watts ?? 0) > 0 ? $0.name : nil }
    }
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
            ProcessMonitorView(rows: processes, didSample: didSampleProcesses)
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
                VStack(alignment: .leading, spacing: 2) {
                    metricValue(readings.health.map { String($0.score) } ?? "—", unit: readings.health?.label ?? "")
                    caption(readings.health?.cause.label ?? tr("正在采样…", "Sampling…"))
                }
                Spacer(minLength: 1)
                caption(tr("运行 ", "Up ") + statusUptime(readings.uptime) + " · " + thermalDescription)
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

    private enum Usage { case cpu, gpu, memory }

    private func trace(_ key: KeyPath<ResourceSample, Double?>, color: Color, peak: Double = 1,
                       sameLink: Bool = false, baseline: Bool = true) -> some View {
        let history = readings.trend
        return MetricTrace(points: history.points(for: key, upperBound: peak, sameLink: sameLink, includeLeading: true),
                           color: color, baseline: baseline, sampleTime: history.samples.last?.date,
                           interval: history.playbackInterval, upperBound: peak)
    }

    private func usage(_ kind: Usage) -> some View {
        let sensor = readings.sensors
        let title = kind == .cpu ? "CPU" : kind == .gpu ? "GPU" : tr("内存", "Memory")
        let color = kind == .cpu ? jade : kind == .gpu ? amber : lilac
        let key: KeyPath<ResourceSample, Double?> = kind == .cpu ? \.cpu : kind == .gpu ? \.gpu : \.memory
        let fraction = readings.trend.samples.last?[keyPath: key]
        let temperature = kind == .cpu ? sensor.cpuCelsius : sensor.gpuCelsius
        let badge = kind == .memory ? readings.vitals.pressure?.label : temperature.map { "\(Int($0.rounded()))°C" }
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
                                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: fraction)
                                        } else { Color.clear.frame(height: 1) }
                                    }
                                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            } else { trace(key, color: color) }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).frame(height: 22)
                    .help(showCores ? tr("每条代表一个核心。点按查看 60 秒趋势。", "Each bar is one core. Click for the 60-second trend.") : tr("点按查看各核心使用率", "Click to show usage by core"))
                    .accessibilityLabel(tr("切换核心读数和 CPU 历史", "Switch between CPU cores and history"))
                } else { trace(key, color: color).frame(height: 22) }
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
                + (readings.gpuWatts.map { " · " + powerReading($0) } ?? "")
        case .memory:
            return (readings.memory.map { memorySize($0.used) + " / " + memorySize($0.total) } ?? "—")
                + (readings.vitals.swap.map { tr(" · 交换 ", " · Swap ") + memorySize($0) } ?? "")
        }
    }

    private var battery: some View {
        let s = readings.sensors
        let watts = s.batteryWatts.map { powerReading(abs($0)) }
        let minutes = s.batteryMinutes.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
        let time = minutes.map { readings.battery.supply == .charging ? tr("\($0) 后充满", "\($0) to full") : tr("剩余 \($0)", "\($0) left") }
        return StatusTile(tint: lime) {
            VStack(alignment: .leading, spacing: 4) {
                headline(tr("电池", "Battery"), "battery.75", color: lime, badge: s.batteryHealthPercent.map { tr("健康 \(Int($0))%", "\(Int($0))% health") })
                Spacer(minLength: 1)
                HStack(alignment: .firstTextBaseline) {
                    metricValue(readings.battery.charge.map { String(Int(($0 * 100).rounded())) } ?? "—", unit: readings.battery.charge == nil ? "" : "%")
                    if let adapter = s.adapterWatts {
                        Label(powerReading(adapter), systemImage: "bolt.fill")
                            .font(.caption).foregroundStyle(lime)
                            .help(tr("当前电源适配器额定功率", "Power adapter rating"))
                    }
                    Spacer(minLength: 1)
                    if let cycles = s.batteryCycles { caption(tr("\(cycles) 次循环", "\(cycles) cycles")) }
                }
                let batteryPower = watts.map { readings.battery.supply == .adapter ? tr("电池 ", "Battery ") + $0 : $0 }
                caption(([readings.battery.supply.description] + [batteryPower, time].compactMap { $0 }).joined(separator: " · "))
                Spacer(minLength: 0)
                if let topPower { caption(tr("CPU 能耗最高 · ", "Top CPU power · ") + topPower) }
            }
        }
    }

    private func gauge(_ value: Double?, _ tint: Color) -> some View {
        GeometryReader { rect in
            Capsule().fill(tint.opacity(0.12)).overlay(alignment: .leading) {
                if let value {
                    Capsule().fill(tint).frame(width: rect.size.width * min(1, max(0, value)))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: value)
                }
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
                if let rates = readings.diskIO { caption(tr("读 ", "R ") + statusRate(rates.read) + tr(" · 写 ", " · W ") + statusRate(rates.write)) }
            }
        }
    }

    private var network: some View {
        let history = readings.trend
        let peak = max(1, history.samples.filter { $0.interface == readings.link }.reduce(0.0) { max($0, $1.down ?? 0, $1.up ?? 0) })
        return StatusTile(tint: sky) {
            VStack(alignment: .leading, spacing: 4) {
                headline(tr("网络", "Network"), "network", color: sky, badge: readings.linkType ?? readings.link)
                Spacer(minLength: 1)
                metricValue(statusRate(readings.throughput?.down))
                ZStack {
                    trace(\.down, color: sky, peak: peak, sameLink: true)
                    trace(\.up, color: jade, peak: peak, sameLink: true, baseline: false)
                }.frame(height: 21)
                Spacer(minLength: 0)
                caption(tr("↑ 上传 ", "↑ Upload ") + statusRate(readings.throughput?.up)
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

@MainActor
struct SystemPage: View {
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var monitor = MonitorSession.shared

    var body: some View {
        StatusBoard(readings: monitor.readings, processes: monitor.processes, didSampleProcesses: monitor.didSampleProcesses)
            .background(StatusWindowDemand(active: phase == .active).frame(width: 0, height: 0))
    }
}

private struct StatusWindowDemand: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) { view.active = active }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.disconnect() }

    final class Observer: NSView {
        private let id = UUID()
        var active = false {
            didSet { if oldValue != active { refreshAfterLayout() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                                       name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            refreshAfterLayout()
        }

        @objc private func occlusionChanged(_ note: Notification) { refreshAfterLayout() }

        private func refreshAfterLayout() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.active, self.window?.occlusionState.contains(.visible) == true {
                    MonitorSession.shared.startWindow(self.id)
                } else {
                    MonitorSession.shared.stopWindow(self.id)
                }
            }
        }

        func disconnect() {
            active = false
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            MonitorSession.shared.stopWindow(id)
        }
    }
}
