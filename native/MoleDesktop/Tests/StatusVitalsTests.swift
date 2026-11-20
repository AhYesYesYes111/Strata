import Foundation

@main
struct StatusVitalsTests {
    static func main() {
        func health(cpu: Double? = 0.04, memory: Double = 0.5, disk: Double = 0.5,
                    pressure: KernelPressure? = nil, temperature: Double? = nil) -> ResourceHealth? {
            ResourceHealth.evaluate(cpu: cpu, memory: memory, disk: disk, pressure: pressure, temperature: temperature,
                                    ioBytesPerSecond: nil, batteryHealth: nil, thermal: nil)
        }
        precondition(health(cpu: nil) == nil)
        precondition(health()?.score == 100)
        precondition(health(pressure: .critical)?.cause == .pressure)
        precondition(health(temperature: 96)?.cause == .thermal)
        precondition(health()?.score ?? 0 > health(memory: 0.95)!.score)
        let sequence = (0...100).map { health(cpu: Double($0) / 100)!.score }
        precondition(zip(sequence, sequence.dropFirst()).allSatisfy { $0 >= $1 })
        precondition(KernelPressure(rawValue: 0) == nil)
        print("Passed missing inputs, health reasons, kernel pressure and monotonic CPU score.")
    }
}
