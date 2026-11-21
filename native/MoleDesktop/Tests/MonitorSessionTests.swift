import Combine
import Foundation
import SwiftUI

@main
enum MonitorSessionTests {
    @MainActor
    static func main() async throws {
        testTracePlayback()
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
        print("PASS continuous trace playback, gaps, scale changes, shared sampling, cancellation, pause and resume")
    }

    @MainActor
    static func testTracePlayback() {
        var history = ResourceTrend()
        func sample(_ second: Int, _ value: Double?, link: String = "en0") -> ResourceSample {
            ResourceSample(date: Date(timeIntervalSinceReferenceDate: Double(second)), cpu: value,
                           memory: nil, down: value, interface: link)
        }
        for second in stride(from: 0, through: 62, by: 2) {
            history.append(sample(second, second == 0 ? 100 : 20))
        }
        precondition(history.playbackInterval == 2 && history.samples.first?.date.timeIntervalSinceReferenceDate == 2)
        let points = history.points(for: \.down, upperBound: 20, sameLink: true, includeLeading: true)
        let size = CGSize(width: 602, height: 103)
        var canvas = TraceCanvas(points: points, color: .white, baseline: false, sampleEnd: 62,
                                 windowEnd: 60, targetBound: 20, displayedBound: 100)
        let oldest = points.first!, newest = points.last!
        precondition(oldest.date.timeIntervalSinceReferenceDate == 0)
        precondition(abs(canvas.position(of: oldest, in: size).y - 1.5) < 0.001)
        let start = canvas.position(of: newest, in: size)
        canvas.animatableData = AnimatablePair(61, 60)
        let middle = canvas.position(of: newest, in: size)
        canvas.animatableData = AnimatablePair(62, 20)
        let end = canvas.position(of: newest, in: size)
        precondition(abs(middle.x - (start.x + end.x) / 2) < 0.001 && start.x > middle.x && middle.x > end.x)
        precondition(start.y > middle.y && middle.y > end.y)
        history.append(sample(64, nil))
        history.append(sample(66, 10))
        let broken = history.points(for: \.down, upperBound: 20, sameLink: true, includeLeading: true)
        precondition(broken.last!.segment != broken.dropLast().last!.segment)
        history.append(sample(68, 15, link: "en1"))
        precondition(history.points(for: \.down, sameLink: true, includeLeading: true).count == 1)
        history.append(sample(80, 12))
        precondition(history.playbackInterval == nil)
        history.append(sample(1, 6))
        precondition(history.playbackInterval == nil && history.points(for: \.down, includeLeading: true).count == 1)
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
