import Foundation

/// The last successful run in each mode. Store only timing offsets for known CLI sections.
struct CleanRunTiming: Codable {
    let seconds: TimeInterval
    let sections: [String: TimeInterval]
    let completed: Date

    static let knownSections: Set<String> = [
        "System", "User essentials", "App caches", "Browsers", "Cloud & Office", "Developer tools",
        "Apps & utilities", "Virtualization", "Application Support", "App leftovers", "Apple Silicon updates",
        "Device backups & firmware", "Time Machine", "Large files", "Project artifacts"
    ]

    fileprivate func usable(at date: Date) -> Bool {
        let age = date.timeIntervalSince(completed)
        return seconds.isFinite && seconds > 0 && seconds <= 610 &&
            age >= 0 && age <= 60 * 60 * 24 * 30
    }
}

struct CleanTimeEstimate {
    let low: TimeInterval
    let high: TimeInterval
    let basis: String
    /// Time, relative to this run's start, at which the estimate applies.
    var anchor: TimeInterval = 0

    var rangeText: String { Self.range(low, high) }

    func remaining(elapsed: TimeInterval) -> String {
        let spent = max(0, elapsed - anchor)
        guard spent < high else { return tr("已超过预估时间，仍在处理", "Taking longer than estimated") }
        if high - spent <= 5 { return tr("预计还需几秒", "A few seconds remaining") }
        if spent >= low {
            let limit = Self.unit(high - spent, up: true)
            return tr("预计剩余 " + limit + "以内", "Up to " + limit + " remaining")
        }
        let window = Self.range(low - spent, high - spent)
        return tr("预计剩余 " + window, window + " remaining")
    }

    private static func range(_ lower: TimeInterval, _ upper: TimeInterval) -> String {
        let from = unit(lower, up: false)
        let to = unit(upper, up: true)
        if from == to { return to }
        let parts = from.split(separator: " ")
        let end = to.split(separator: " ")
        if parts.count == 2, end.count == 2, parts[1] == end[1] {
            return parts[0] + "–" + to
        }
        return from + "–" + to
    }

    private static func unit(_ seconds: TimeInterval, up: Bool) -> String {
        let step: Double = seconds >= 120 ? 60 : seconds >= 60 ? 30 : 5
        let scaled = max(0, seconds) / step
        let value = Int(max(5, (up ? ceil(scaled) : floor(scaled)) * step))
        if value < 60 { return tr("\(value) 秒", "\(value) sec") }
        if value % 60 == 0 { return tr("\(value / 60) 分钟", "\(value / 60) min") }
        return tr("\(value / 60) 分 \(value % 60) 秒", "\(value / 60) min \(value % 60) sec")
    }
}

struct CleanTimingHistory {
    enum Mode: String { case scan, clean }
    let defaults: UserDefaults
    private var scan: CleanRunTiming?
    private var clean: CleanRunTiming?

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        for mode in [Mode.scan, .clean] {
            if let data = defaults.data(forKey: Self.key(mode)),
               let sample = try? JSONDecoder().decode(CleanRunTiming.self, from: data),
               sample.usable(at: now) {
                if mode == .scan { scan = sample } else { clean = sample }
            }
        }
    }

    mutating func record(_ sample: CleanRunTiming, for mode: Mode) {
        guard sample.usable(at: Date()), let data = try? JSONEncoder().encode(sample) else { return }
        if mode == .scan { scan = sample } else { clean = sample }
        defaults.set(data, forKey: Self.key(mode))
    }

    /// Matched section starts let later stages correct an early overrun.
    func estimate(_ mode: Mode, section: String = "", entered: TimeInterval = 0,
                  now: Date = Date()) -> CleanTimeEstimate {
        let previous = mode == .scan ? scan : clean
        if let previous, previous.usable(at: now) {
            return estimate(previous, section: section, entered: entered, coarse: false,
                            basis: mode == .scan ? tr("参考上次扫描", "Last scan") : tr("参考上次清理", "Last cleanup"))
        }
        if mode == .clean, let scan, scan.usable(at: now) {
            // A full clean repeats discovery and adds removal. A preview is a rough proxy only.
            return estimate(scan, section: section, entered: entered, coarse: true, basis: tr("按扫描耗时粗估", "Based on scan time"))
        }
        // The read-only measurement in docs/weekly-audit.md was about 60 seconds.
        // The first-run window is intentionally broad; device, permissions and workload vary.
        return mode == .scan
            ? CleanTimeEstimate(low: 30, high: 180, basis: tr("首次粗估", "First-run estimate"))
            : CleanTimeEstimate(low: 60, high: 300, basis: tr("首次粗估", "First-run estimate"))
    }

    private func estimate(_ sample: CleanRunTiming, section: String, entered: TimeInterval,
                          coarse: Bool, basis: String) -> CleanTimeEstimate {
        let offset = sample.sections[section].flatMap { (0...sample.seconds).contains($0) ? $0 : nil }
        let seconds = sample.seconds - (offset ?? 0)
        // Round to coarse windows. Never present the subprocess's ten-minute deadline as an ETA.
        let low = max(5, seconds * (coarse ? 0.75 : 0.70))
        let high = max(low + 5, min(600, seconds * (coarse ? 3 : 1.45)))
        return CleanTimeEstimate(low: low, high: high, basis: basis, anchor: offset == nil ? 0 : entered)
    }

    private static func key(_ mode: Mode) -> String { "strata.timing.v1." + mode.rawValue }
}
