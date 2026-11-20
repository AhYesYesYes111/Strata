import Foundation

@main struct HardwareCounterTests {
    static func main() {
        let disk = StorageCounters(driver: 4, read: 10, written: 20, time: 2)
        func diskRate(_ time: Double, _ read: UInt64, _ write: UInt64, driver: UInt64 = 4) -> (read: Double, write: Double)? {
            StorageCounters(driver: driver, read: read, written: write, time: time).rates(since: disk)
        }
        precondition(diskRate(4, 20, 30)?.read == 5 && diskRate(4, 20, 30)?.write == 5)
        precondition(diskRate(4, 10, 20)?.read == 0)
        precondition(diskRate(4, 9, 20) == nil && diskRate(4, 10, 19) == nil)
        precondition(diskRate(4, 20, 30, driver: 5) == nil)
        precondition(diskRate(2, 20, 30) == nil && diskRate(20, 20, 30) == nil)

        let energy = GPUEnergyReading(ticks: 1_000_000_000, joulesPerTick: 1e-9, time: 1)
        func watts(_ ticks: Int64, time: Double = 3, scale: Double = 1e-9) -> Double? {
            GPUEnergyReading(ticks: ticks, joulesPerTick: scale, time: time).watts(since: energy)
        }
        precondition(watts(3_000_000_000) == 1)
        precondition(watts(3_000_000_000, scale: 1e-3) == nil)
        precondition(watts(1_000_000_000) == nil && watts(1) == nil)
        precondition(watts(3_000_000_000, time: 1) == nil && watts(3_000_000_000, time: 25) == nil)
        precondition(HardwareTelemetry().gpuPower(since: HardwareTelemetry()) == nil)
        precondition(HardwareTelemetry().diskRates(since: HardwareTelemetry()) == nil)
        print("Hardware counter tests passed: physical driver identity, resets, gaps, units, missing and stalled energy.")
    }
}
