import AppKit
import Combine
import Foundation
import QuartzCore
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
        try await wait { monitor.readings.trend.samples.count >= 2 }
        precondition(processUpdates == 0 && !monitor.didSampleProcesses, "The menu only needs hardware readings")
        let samples = monitor.readings.trend.samples.count
        let initialUpdates = statusUpdates
        monitor.startMenu()
        monitor.startWindow(window)
        monitor.startWindow(window)
        monitor.stopMenu()
        monitor.stopMenu()
        precondition(statusUpdates == initialUpdates, "Adding another surface must reuse the running sampler")
        try await wait { monitor.readings.trend.samples.count > samples && monitor.didSampleProcesses }
        monitor.startMenu()
        monitor.stopWindow(window)
        let menuOnlyProcesses = processUpdates
        let menuOnlyStatus = statusUpdates
        try await Task.sleep(nanoseconds: 3_250_000_000)
        precondition(menuOnlyProcesses == processUpdates && statusUpdates > menuOnlyStatus,
                     "Closing the last status window stops process updates while the menu continues")
        monitor.stopMenu()
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
        for second in stride(from: 0, through: 60, by: 2) {
            history.append(sample(second, second == 0 ? 100 : 20))
        }
        let size = CGSize(width: 602, height: 103)
        let view = TraceLayerView(frame: CGRect(origin: .zero, size: size))
        view.update(points: history.points(for: \.down, upperBound: 100, sameLink: true, includeLeading: true),
                    color: .red, baseline: true, sampleEnd: 60, displayedBound: 100, targetBound: 100, interval: 2)
        precondition(view.moving.animation(forKey: "scroll") == nil, "First sample must appear immediately")

        history.append(sample(62, 20))
        precondition(history.playbackInterval == 2 && history.samples.first?.date.timeIntervalSinceReferenceDate == 2)
        let points = history.points(for: \.down, upperBound: 20, sameLink: true, includeLeading: true)
        let oldest = points.first!, newest = points.last!
        precondition(oldest.date.timeIntervalSinceReferenceDate == 0)
        view.update(points: points, color: .red, baseline: true, sampleEnd: 62,
                    displayedBound: 100, targetBound: 20, interval: 2)
        guard let scroll = view.moving.animation(forKey: "scroll") as? CABasicAnimation else {
            preconditionFailure("A new sample must schedule compositor scrolling")
        }
        precondition(scroll.keyPath == "transform.translation.x" && scroll.duration == 2)
        // A 600pt plotting area covers 60s. The new geometry starts 20pt to the right.
        precondition((scroll.fromValue as? NSNumber)?.doubleValue == 20 && (scroll.toValue as? NSNumber)?.doubleValue == 0)
        precondition(view.layer?.masksToBounds == true && view.stroke.superlayer === view.moving)
        precondition(view.dots.superlayer === view.moving && view.baselineLayer.superlayer === view.layer)
        precondition(!view.baselineLayer.isHidden && (view.baselineLayer.backgroundColor?.alpha ?? 0) > 0)
        let leading = oldest.position(in: size, targetBound: 20, displayedBound: 100)
        precondition(abs(leading.x + 19) < 0.001 && abs(leading.y - 1.5) < 0.001)
        precondition(abs(view.dots.path!.boundingBoxOfPath.midX - leading.x) < 0.001)

        // The scale interpolates linearly; the height varies inversely with that scale.
        for bound in [100.0, 60.0] {
            view.update(points: points, color: .blue, baseline: true, sampleEnd: 62,
                        displayedBound: bound, targetBound: 20, interval: 2)
            let p = view.stroke.path!.currentPoint
            precondition(abs(p.x - 601) < 0.001 && abs(p.y - ((1 - 20 / bound) * 100 + 1.5)) < 0.001)
        }
        precondition(view.stroke.strokeColor == NSColor.blue.cgColor)
        let smaller = CGSize(width: 302, height: 103)
        view.setFrameSize(smaller)
        view.layoutSubtreeIfNeeded()
        precondition(abs(view.stroke.path!.currentPoint.x - 301) < 0.001, "Resize must rebuild the path even without a new sample")
        let resized = view.moving.animation(forKey: "scroll") as? CABasicAnimation
        precondition((resized?.fromValue as? NSNumber)?.doubleValue == 10 && resized?.beginTime == scroll.beginTime,
                     "Resizing during playback must preserve the time offset and finish time")
        view.update(points: points, color: .blue, baseline: true, sampleEnd: 62,
                    displayedBound: 60, targetBound: 20, interval: nil)
        precondition(view.moving.animation(forKey: "scroll") == nil, "Disabling motion must stop in-flight scrolling")
        precondition(view.stroke.path!.currentPoint == newest.position(in: smaller, targetBound: 20, displayedBound: 20),
                     "Disabling motion mid-rescale must immediately show the final vertical scale")

        history.append(sample(64, nil))
        history.append(sample(66, 10))
        history.append(sample(68, 15))
        let broken = history.points(for: \.down, upperBound: 20, sameLink: true, includeLeading: true)
        precondition(broken.first!.segment != broken.last!.segment)
        view.update(points: broken, color: .blue, baseline: false, sampleEnd: 68,
                    displayedBound: 20, targetBound: 20, interval: 2)
        var starts = 0
        view.stroke.path!.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { starts += 1 }
        }
        precondition(starts == 2, "A missing reading must leave a break in the actual stroke")
        precondition(view.baselineLayer.isHidden || (view.baselineLayer.backgroundColor?.alpha ?? 0) == 0)
        history.append(sample(70, 15, link: "en1"))
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
