import Combine
import Foundation

@main
enum MonitorSessionTests {
    @MainActor
    static func main() async throws {
        let monitor = MonitorSession()
        let window = UUID()
        var statusUpdates = 0
        var processUpdates = 0
        var firstCPU: Double?
        var firstNetwork: Double?
        let statusSubscription = monitor.$readings.dropFirst().sink { reading in
            if statusUpdates == 1 {
                firstCPU = reading.cpu
                firstNetwork = reading.throughput?.down
            }
            statusUpdates += 1
        }
        let processSubscription = monitor.$processes.dropFirst().sink { _ in processUpdates += 1 }

        monitor.startMenu()
        try await wait { monitor.readings.trend.samples.count >= 2 && monitor.didSampleProcesses }
        let samples = monitor.readings.trend.samples.count
        let initialUpdates = statusUpdates
        monitor.startMenu()
        monitor.startWindow(window)
        monitor.startWindow(window)
        monitor.stopMenu()
        monitor.stopMenu()
        precondition(statusUpdates == initialUpdates, "Adding another surface must reuse the running sampler")
        try await wait { monitor.readings.trend.samples.count > samples }
        monitor.stopWindow(window)
        let stoppedStatus = statusUpdates
        let stoppedProcesses = processUpdates
        try await Task.sleep(nanoseconds: 3_250_000_000)
        precondition(statusUpdates == stoppedStatus && processUpdates == stoppedProcesses, "Hidden surfaces must stop sampling")

        statusUpdates = 0
        let lastDate = monitor.readings.trend.samples.last?.date
        monitor.startMenu()
        try await wait { monitor.readings.trend.samples.last?.date != lastDate }
        precondition(firstCPU == nil && firstNetwork == nil, "A resumed session must establish fresh rate baselines")
        precondition(monitor.readings.trend.samples.contains { $0.date == lastDate }, "Keep the recent graph across a brief pause")
        monitor.stopMenu()
        withExtendedLifetime((statusSubscription, processSubscription)) {}
        print("PASS shared sampling, cancellation, pause and resume")
    }

    @MainActor
    static func wait(until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !ready() {
            precondition(ContinuousClock.now < deadline, "Timed out waiting for a sample")
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }
}
