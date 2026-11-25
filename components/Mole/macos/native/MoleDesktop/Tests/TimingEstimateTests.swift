import Foundation

@main
struct TimingEstimateTests {
    static func main() {
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.key)
        let domain = "local.strata.timing-fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }

        let now = Date().addingTimeInterval(-1)
        var timings = CleanTimingHistory(defaults: defaults, now: now)
        let firstScan = timings.estimate(.scan)
        let firstClean = timings.estimate(.clean)
        precondition(firstScan.basis == "首次粗估" && firstScan.low < firstScan.high)
        precondition(firstClean.basis == "首次粗估" && firstClean.high > firstScan.high)
        precondition(!firstScan.remaining(elapsed: firstScan.high - 0.5).contains("0 秒"))
        precondition(firstScan.remaining(elapsed: firstScan.high).contains("超过"))

        let preview = CleanRunTiming(seconds: 80, sections: ["Browsers": 25], completed: now)
        timings.record(preview, for: .scan)
        let restored = CleanTimingHistory(defaults: defaults)
        let byScan = restored.estimate(.clean)
        precondition(byScan.basis == "按扫描耗时粗估" && byScan.low <= 80 && byScan.high >= 80)
        let bySection = restored.estimate(.scan, section: "Browsers", entered: 110)
        precondition(bySection.basis == "参考上次扫描" && bySection.anchor == 110)
        precondition(!bySection.remaining(elapsed: 115).contains("超过"))

        let execution = CleanRunTiming(seconds: 205, sections: ["Browsers": 30], completed: now)
        timings.record(execution, for: .clean)
        precondition(timings.estimate(.scan).high == restored.estimate(.scan).high)
        let clean = timings.estimate(.clean, section: "unseen", entered: 44)
        precondition(clean.basis == "参考上次清理" && clean.anchor == 0)
        precondition(clean.low <= 205 && clean.high >= 205)
        timings.record(CleanRunTiming(seconds: .infinity, sections: [:], completed: now), for: .clean)
        precondition(timings.estimate(.clean).rangeText == clean.rangeText)
        let stale = now.addingTimeInterval(31 * 86400)
        precondition(timings.estimate(.scan, now: stale).basis == "首次粗估")
        precondition(CleanTimingHistory(defaults: defaults, now: stale).estimate(.clean).basis == "首次粗估")
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.key)
        let english = timings.estimate(.scan, now: stale)
        precondition(english.rangeText == "30 sec–3 min")
        precondition(english.remaining(elapsed: english.high) == "Taking longer than estimated")
        precondition(timings.estimate(.clean).basis == "Last cleanup")
        print("Passed bilingual cold, historical and per-section ETA; persisted modes, stale and invalid samples, overrun")
    }
}
