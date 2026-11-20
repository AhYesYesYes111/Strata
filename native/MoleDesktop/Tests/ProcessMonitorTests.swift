import Foundation

@main
struct ProcessMonitorTests {
    static func main() async throws {
        let before = ProcessCounters(cpu: 500, energy: 200, stamp: 1_000)
        let now = ProcessCounters(cpu: 700, energy: 520, stamp: 1_100)
        let rates = now.rates(since: before, nanosecondsPerTick: 40)
        precondition(rates.cpu == 200 && rates.watts == 0.08)
        precondition(now.rates(since: nil, nanosecondsPerTick: 40).cpu == nil)
        let reset = ProcessCounters(cpu: 20, energy: 0, stamp: 1_200)
        let cleared = reset.rates(since: now, nanosecondsPerTick: 40)
        precondition(cleared.cpu == nil && cleared.watts == nil)
        let late = ProcessCounters(cpu: 800, energy: 560, stamp: 550_001_000)
        precondition(late.rates(since: now, nanosecondsPerTick: 40).watts == nil)
        let oldID = MonitorProcessID(pid: 42, birth: "1000")
        let newID = MonitorProcessID(pid: 42, birth: "9000")
        let previous = [oldID: before]
        precondition(now.rates(since: previous[newID], nanosecondsPerTick: 40).watts == nil)

        let sampler = ProcessSampler()
        let start = Date()
        let first = try await sampler.sample()
        let elapsed = Date().timeIntervalSince(start)
        precondition(!first.isEmpty && Set(first.map(\.id)).count == first.count)
        precondition(first.allSatisfy { $0.watts == nil })
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let second = try await sampler.sample()
        precondition(second.contains { $0.memory > 0 && $0.cpu != nil })
        precondition(second.allSatisfy { ($0.cpu ?? 0) >= 0 && ($0.watts ?? 0) >= 0 })
        precondition(second.filter(\.isResidentSize).allSatisfy { $0.watts == nil })
        print("Process delta, energy and identity fixtures passed. Live rows:", second.count,
              "with readable watts:", second.filter { $0.watts != nil }.count,
              "with system RSS:", second.filter(\.isResidentSize).count,
              "first sweep (ms):", Int(elapsed * 1000))
    }
}
