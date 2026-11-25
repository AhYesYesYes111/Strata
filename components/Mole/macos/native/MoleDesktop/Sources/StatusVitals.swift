import Darwin
import Foundation

enum KernelPressure: Int32 {
    case normal = 1, elevated = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return tr("压力正常", "Normal pressure")
        case .elevated: return tr("压力偏高", "High pressure")
        case .critical: return tr("压力严重", "Critical pressure")
        }
    }
}

struct SystemVitals {
    var load: Double?
    var swap: UInt64?
    var pressure: KernelPressure?

    static func read() -> Self {
        var reading = Self()
        var average = 0.0
        if getloadavg(&average, 1) == 1 { reading.load = average }
        var usage = xsw_usage()
        var length = MemoryLayout.size(ofValue: usage)
        if sysctlbyname("vm.swapusage", &usage, &length, nil, 0) == 0, length == MemoryLayout.size(ofValue: usage) {
            reading.swap = usage.xsu_used
        }
        var level: Int32 = 0
        length = MemoryLayout.size(ofValue: level)
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) == 0, length == MemoryLayout.size(ofValue: level) {
            reading.pressure = KernelPressure(rawValue: level)
        }
        return reading
    }
}

// Uses the resource thresholds from Mole CLI's cmd/status/metrics_health.go.
// Optional sensors contribute only when the current sample actually has a reading.
struct ResourceHealth {
    enum Cause {
        case normal, cpu, memory, pressure, disk, thermal, io, battery
        var label: String {
            switch self {
            case .normal: return tr("各项指标平稳", "Within normal ranges")
            case .cpu: return tr("CPU 负载偏高", "High CPU load")
            case .memory: return tr("内存使用率偏高", "High memory use")
            case .pressure: return tr("内存压力偏高", "Elevated memory pressure")
            case .disk: return tr("磁盘使用率偏高", "High disk usage")
            case .thermal: return tr("温度偏高", "Elevated temperature")
            case .io: return tr("磁盘读写繁忙", "Heavy disk I/O")
            case .battery: return tr("电池容量衰减", "Battery wear")
            }
        }
    }

    var score: Int
    var cause: Cause
    var label: String {
        switch score {
        case 85...100: return tr("极佳", "Excellent")
        case 65..<85: return tr("良好", "Good")
        case 45..<65: return tr("一般", "Fair")
        default: return tr("需关注", "Needs attention")
        }
    }

    static func evaluate(cpu: Double?, memory: Double?, disk: Double?, pressure: KernelPressure?,
                         temperature: Double?, ioBytesPerSecond: Double?, batteryHealth: Double?,
                         thermal: ProcessInfo.ThermalState?) -> Self? {
        guard let cpu, let memory, let disk else { return nil }
        func penalty(_ value: Double, normal: Double, high: Double, weight: Double) -> Double {
            guard value > normal else { return 0 }
            if value <= high { return weight / 2 * (value - normal) / (high - normal) }
            return weight * (value - normal) / (1 - normal)
        }
        let normalTempPenalty = temperature.map { min(15, max(0, ($0 - 65) * 0.75)) } ?? 0
        let heat = max(normalTempPenalty, thermal == .critical ? 15 : thermal == .serious ? 10 : 0)
        let ioPenalty = ioBytesPerSecond.map { min(10, max(0, ($0 / 1_000_000 - 50) / 10)) } ?? 0
        let batteryPenalty = batteryHealth.map { $0 < 60 ? 5.0 : $0 < 80 ? 2.0 : 0 } ?? 0
        let factors: [(Cause, Double)] = [
            (.cpu, penalty(cpu, normal: 0.50, high: 0.85, weight: 30)),
            (.memory, penalty(memory, normal: 0.70, high: 0.88, weight: 25)),
            (.disk, penalty(disk, normal: 0.80, high: 0.93, weight: 20)),
            (.pressure, pressure == .critical ? 15 : pressure == .elevated ? 5 : 0),
            (.thermal, heat), (.io, ioPenalty), (.battery, batteryPenalty)
        ]
        let dominant = factors.max { $0.1 < $1.1 }
        let score = 100 - factors.reduce(0.0) { $0 + $1.1 }
        return Self(score: Int(max(0, score)), cause: dominant.flatMap { $0.1 > 0 ? $0.0 : nil } ?? .normal)
    }
}
