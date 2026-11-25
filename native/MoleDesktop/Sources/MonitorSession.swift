import Combine
import Foundation

private actor StatusSampler {
    private var readings: StatusReadings

    init(history: ResourceTrend) {
        readings = StatusReadings(history: history)
    }

    func sample() throws -> StatusReadings {
        try Task.checkCancellation()
        readings.sample()
        return readings
    }
}

@MainActor
final class MonitorSession: ObservableObject {
    static let shared = MonitorSession()

    @Published private(set) var readings = StatusReadings()
    @Published private(set) var processes: [ProcessReading] = []
    @Published private(set) var didSampleProcesses = false

    private enum Surface: Hashable {
        case menu
        case window(UUID)
    }

    private var visible: Set<Surface> = []
    private var statusTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?

    func startMenu() { show(.menu) }
    func stopMenu() { hide(.menu) }
    func startWindow(_ id: UUID) { show(.window(id)) }
    func stopWindow(_ id: UUID) { hide(.window(id)) }

    private func show(_ surface: Surface) {
        guard visible.insert(surface).inserted else { return }
        if statusTask == nil {
            // Keep recent history, but always establish fresh rate baselines after a pause.
            let history = readings.trend
            readings = StatusReadings(history: history)
            let status = StatusSampler(history: history)
            statusTask = poll(every: 2_000_000_000) { [weak self] in
                let result = try await status.sample()
                try Task.checkCancellation()
                self?.readings = result
            }
        }
        guard case .window = surface, processTask == nil else { return }
        processes = []
        didSampleProcesses = false
        let process = ProcessSampler()
        processTask = poll(every: 3_000_000_000) { [weak self] in
            let result = try await process.sample()
            try Task.checkCancellation()
            self?.didSampleProcesses = true
            self?.processes = result
        }
    }

    private func hide(_ surface: Surface) {
        guard visible.remove(surface) != nil else { return }
        if visible.isSubset(of: [.menu]) {
            processTask?.cancel()
            processTask = nil
        }
        if visible.isEmpty {
            statusTask?.cancel()
            statusTask = nil
        }
    }

    private func poll(every interval: UInt64, sample: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        Task {
            // CPU and throughput need two measurements before they have a value.
            var delay: UInt64 = 650_000_000
            do {
                while !Task.isCancelled {
                    try await sample()
                    try await Task.sleep(nanoseconds: delay)
                    delay = interval
                }
            } catch { return }
        }
    }
}
