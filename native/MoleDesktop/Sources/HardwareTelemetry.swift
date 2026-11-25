import Darwin
import Foundation
import IOKit

/// Read-only, hardware-dependent values. Nil means the driver did not publish a reading.
struct HardwareTelemetry {
    var cpuCelsius: Double?
    var gpuCelsius: Double?
    var gpuPercent: Double?
    var gpuCores: Int?
    var fanRPM: Double?
    var fanPercent: Double?
    var fanCount: Int?
    var fanAutomatic: Bool?
    var batteryCycles: Int?
    var batteryHealthPercent: Double?
    var batteryWatts: Double?
    var adapterWatts: Double?
    var batteryMinutes: Int?

    fileprivate var disk: StorageCounters?
    fileprivate var energy: GPUEnergyReading?

    func diskRates(since previous: Self) -> (read: Double, write: Double)? {
        guard let current = disk, let past = previous.disk else { return nil }
        return current.rates(since: past)
    }

    func gpuPower(since previous: Self) -> Double? {
        guard let current = energy, let past = previous.energy else { return nil }
        return current.watts(since: past)
    }

    fileprivate mutating func readBattery(_ entry: io_service_t) {
        func number(_ key: String) -> NSNumber? { Registry.value(entry, key) as? NSNumber }
        batteryCycles = number("CycleCount")?.intValue
        batteryHealthPercent = BatteryHealthCache.shared.latest()
        if let voltage = number("Voltage")?.doubleValue, let current = number("Amperage") {
            // The registry sometimes wraps a negative discharging current in UInt64.
            let amps = current.int64Value
            if (1000...40000).contains(voltage), (-50000...50000).contains(amps) {
                batteryWatts = Double(amps) * voltage / 1_000_000
            }
        }
        let connected = number("ExternalConnected")?.boolValue
        if connected == true, let adapter = Registry.value(entry, "AdapterDetails") as? [String: Any],
           let watts = (adapter["Watts"] as? NSNumber)?.doubleValue, watts > 0 { adapterWatts = watts }
        if number("IsCharging")?.boolValue == true {
            batteryMinutes = number("AvgTimeToFull")?.intValue
        } else if connected == false {
            batteryMinutes = number("AvgTimeToEmpty")?.intValue ?? number("TimeRemaining")?.intValue
        }
        if let minutes = batteryMinutes, !(1..<14400).contains(minutes) { batteryMinutes = nil }
    }
}

/// The status sampler owns these handles only while a monitoring surface is visible.
final class HardwareSampler {
    private var controller: SMCReader?
    private var gpuSubscription: GPUReport.Subscription?
    private let storage = StorageReader()

    func read() -> HardwareTelemetry {
        var result = HardwareTelemetry()
        if let gpu = Registry.service("IOAccelerator") {
            defer { IOObjectRelease(gpu) }
            let stats = Registry.value(gpu, "PerformanceStatistics") as? [String: Any]
            if let percent = (stats?["Device Utilization %"] as? NSNumber)?.doubleValue,
               (0...100).contains(percent) { result.gpuPercent = percent }
            result.gpuCores = (Registry.value(gpu, "gpu-core-count") as? NSNumber)?.intValue
        }
        if let battery = Registry.service("AppleSmartBattery") {
            defer { IOObjectRelease(battery) }
            result.readBattery(battery)
        }
        if controller == nil { controller = SMCReader() }
        controller?.sample(into: &result)
        if controller?.disconnected == true { controller = nil }
        result.disk = storage.read()
        if gpuSubscription == nil { gpuSubscription = GPUReport.functions?.openSubscription() }
        if let gpuSubscription {
            result.energy = GPUReport.functions?.sample(gpuSubscription)
            if result.energy == nil { self.gpuSubscription = nil }
        }
        return result
    }
}

private enum Registry {
    static func service(_ name: String) -> io_service_t? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        return entry == 0 ? nil : entry
    }
    static func value(_ entry: io_registry_entry_t, _ name: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

struct StorageCounters {
    let driver: UInt64
    let read: UInt64
    let written: UInt64
    let time: TimeInterval

    func rates(since previous: Self) -> (read: Double, write: Double)? {
        let duration = time - previous.time
        guard driver == previous.driver, duration > 0, duration <= 10,
              read >= previous.read, written >= previous.written else { return nil }
        return (Double(read - previous.read) / duration, Double(written - previous.written) / duration)
    }
}

private final class StorageReader {
    private var mountSource: String?
    private var driver: io_registry_entry_t = 0

    deinit { if driver != 0 { IOObjectRelease(driver) } }

    func read() -> StorageCounters? {
        var fs = statfs()
        guard statfs("/System/Volumes/Data", &fs) == 0 else { return nil }
        let source = withUnsafeBytes(of: &fs.f_mntfromname) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        if mountSource == source, driver != 0, let counters = readDriver() { return counters }

        if driver != 0 { IOObjectRelease(driver) }
        driver = 0
        mountSource = source
        guard source.hasPrefix("/dev/"), let match = IOBSDNameMatching(kIOMainPortDefault, 0, String(source.dropFirst(5))) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        // Walk the startup Data volume to its backing driver. External drives and disk
        // images have their own counters and must not inflate this card's rates.
        for _ in 0..<48 {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 {
                IOObjectRetain(entry)
                driver = entry
                return readDriver()
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(entry)
            entry = parent
        }
        return nil
    }

    private func readDriver() -> StorageCounters? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(driver, &id) == KERN_SUCCESS,
              let stats = Registry.value(driver, "Statistics") as? [String: Any],
              let read = stats["Bytes (Read)"] as? NSNumber,
              let written = stats["Bytes (Write)"] as? NSNumber else { return nil }
        return StorageCounters(driver: id, read: read.uint64Value, written: written.uint64Value,
                               time: ProcessInfo.processInfo.systemUptime)
    }
}

/// macOS applies its own calibration to battery health. Cache the same percentage as
/// System Information, since raw charge/design ratios can differ by several points.
private final class BatteryHealthCache: @unchecked Sendable {
    static let shared = BatteryHealthCache()
    private let lock = NSLock()
    private var value: Double?
    private var lastRequest: TimeInterval?
    private var pending = false

    func latest() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if !pending && (lastRequest.map { now - $0 >= 600 } ?? true) {
            pending = true
            lastRequest = now
            DispatchQueue.global(qos: .utility).async {
                let fresh = Self.read()
                self.lock.lock()
                self.value = fresh
                self.pending = false
                self.lock.unlock()
            }
        }
        return value
    }

    private static func read() -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-timeout", "3", "SPPowerDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
        defer { watchdog.cancel(); try? pipe.fileHandleForReading.close() }
        var data = Data()
        while let part = try? pipe.fileHandleForReading.read(upToCount: 16384), !part.isEmpty {
            guard data.count + part.count <= 256 * 1024 else { if process.isRunning { process.terminate() }; return nil }
            data.append(part)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for device in devices {
            guard let info = device["sppower_battery_health_info"] as? [String: Any],
                  let percent = info["sppower_battery_health_maximum_capacity"] as? String,
                  let n = Double(percent.trimmingCharacters(in: CharacterSet(charactersIn: "% "))), (0...100).contains(n) else { continue }
            return n
        }
        return nil
    }
}

/// Read commands for the AppleSMC user client. Its message has a fixed 80-byte ABI
/// on Intel and ARM. The only operations used here are key information (9) and read (5).
private final class SMCReader {
    private var connection: io_connect_t = 0
    private var formats: [UInt32: (size: UInt32, type: UInt32)] = [:]
    private(set) var disconnected = false

    init?() {
        guard let service = Registry.service("AppleSMC") else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(key: UInt32, command: UInt8, size: UInt32 = 0) -> Data? {
        var request = Data(count: 80)
        request.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: key, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
            raw[42] = command
        }
        var reply = Data(count: 80)
        var received = 80
        let status = request.withUnsafeBytes { input in reply.withUnsafeMutableBytes { output in
            IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count, output.baseAddress, &received)
        } }
        guard status == KERN_SUCCESS else {
            disconnected = true
            return nil
        }
        guard received == 80, reply[40] == 0 else { return nil }
        return reply
    }

    private func value(_ name: String) -> Double? {
        let key = name.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let format: (size: UInt32, type: UInt32)
        if let cached = formats[key] {
            format = cached
        } else {
            guard let info = call(key: key, command: 9) else { return nil }
            format = info.withUnsafeBytes {
                ($0.loadUnaligned(fromByteOffset: 28, as: UInt32.self), $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self))
            }
            guard (1...32).contains(format.size) else { return nil }
            formats[key] = format
        }
        guard let result = call(key: key, command: 5, size: format.size) else {
            formats.removeValue(forKey: key)
            return nil
        }
        switch (format.type, format.size) {
        case (0x666c7420,4): // flt
            return Double(result.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 48, as: Float.self) })
        case (0x73703738,2): // sp78
            return Double(Int16(bitPattern: UInt16(result[48]) << 8 | UInt16(result[49]))) / 256
        case (0x66706532,2): // fpe2
            return Double(UInt16(result[48]) << 8 | UInt16(result[49])) / 4
        case (0x75693820,1): // ui8
            return Double(result[48])
        default: return nil
        }
    }

    func sample(into result: inout HardwareTelemetry) {
        let probes = Self.temperatureKeys
        result.cpuCelsius = averageTemperature(probes.cpu)
        result.gpuCelsius = averageTemperature(probes.gpu)
        guard let count = value("FNum"), (0...12).contains(count) else { return }
        result.fanCount = Int(count)
        // Show the fastest measured fan and the corresponding fraction of its own max.
        for i in 0..<Int(count) {
            guard let rpm = value("F\(i)Ac"), (0...25000).contains(rpm),
                  rpm > (result.fanRPM ?? -1) else { continue }
            result.fanRPM = rpm
            switch value("F\(i)Md") ?? value("F\(i)md") {
            case 0, 3: result.fanAutomatic = true
            case 1: result.fanAutomatic = false
            default: result.fanAutomatic = nil
            }
            result.fanPercent = nil
            if let maximum = value("F\(i)Mx"), maximum > 0, maximum >= rpm {
                result.fanPercent = 100 * rpm / maximum
            }
        }
    }

    private func averageTemperature(_ keys: [String]) -> Double? {
        let readings = keys.compactMap(value).filter { (15...125).contains($0) }
        return readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
    }

    // Only use sensor names associated with the core type on this chip generation.
    // Known key families are documented in exelban/stats, Modules/Sensors/values.swift.
    private static let temperatureKeys: (cpu: [String], gpu: [String]) = {
        var size = 256
        var bytes = [CChar](repeating: 0, count: size)
        _ = sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let chip = String(cString: bytes)
        if chip.contains("Apple M1") {
            return (["Tp09","Tp0T","Tp01","Tp05","Tp0D","Tp0H","Tp0L","Tp0P","Tp0X","Tp0b"], ["Tg05","Tg0D","Tg0L","Tg0T"])
        } else if chip.contains("Apple M2") {
            return (["Tp1h","Tp1t","Tp1p","Tp1l","Tp01","Tp05","Tp09","Tp0D","Tp0X","Tp0b","Tp0f","Tp0j"], ["Tg0f","Tg0j"])
        } else if chip.contains("Apple M3") {
            return (["Te05","Te0L","Te0P","Te0S","Tf04","Tf09","Tf0A","Tf0B","Tf0D","Tf0E","Tf44","Tf49","Tf4A","Tf4B","Tf4D","Tf4E"], ["Tf14","Tf18","Tf19","Tf1A","Tf24","Tf28","Tf29","Tf2A"])
        } else if chip.contains("Apple M4") {
            return (["Te05","Te0S","Te09","Te0H","Te06","Te0T","Tp01","Tp05","Tp09","Tp0D","Tp0V","Tp0Y","Tp0b","Tp0e","Tp0H"], ["Tg0G","Tg0H","Tg1U","Tg1k","Tg0K","Tg0L","Tg0d","Tg0e","Tg0j","Tg0k"])
        } else if chip.contains("Apple M5") {
            return (["Tp00","Tp04","Tp08","Tp0C","Tp0G","Tp0K","Tp0O","Tp0R","Tp0U","Tp0X","Tp0a","Tp0d","Tp0g","Tp0j","Tp0m","Tp0p","Tp0u","Tp0y"], ["Tg0U","Tg0X","Tg0d","Tg0g","Tg0j","Tg1Y","Tg1c","Tg1g"])
        } else if chip.contains("Intel") {
            return (["TC0D","TC0F","TC0E"], ["TG0D","TG0P"])
        }
        return ([], [])
    }()
}

struct GPUEnergyReading {
    let ticks: Int64
    let joulesPerTick: Double
    let time: TimeInterval

    func watts(since previous: Self) -> Double? {
        let interval = time - previous.time
        // Some OS/driver pairs expose the channel but never advance it. An unchanged
        // counter cannot distinguish a completely idle GPU from an unavailable reading.
        guard interval > 0, interval <= 10, ticks > previous.ticks,
              previous.ticks >= 0, joulesPerTick.isFinite, joulesPerTick > 0, joulesPerTick == previous.joulesPerTick else { return nil }
        return Double(ticks - previous.ticks) * joulesPerTick / interval
    }
}

/// Resolve the optional IOReport interface once. Each active sampler owns its subscription.
private struct GPUReport {
    private typealias Channels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias Subscribe = @convention(c) (CFAllocator?, CFDictionary, UnsafeMutablePointer<Unmanaged<CFDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    private typealias Samples = @convention(c) (CFTypeRef, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Label = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Count = @convention(c) (CFDictionary, UnsafeRawPointer?) -> Int64

    static let functions = GPUReport()
    private let channels: CFDictionary
    private let subscribe: Subscribe
    private let samples: Samples
    private let name: Label
    private let unit: Label
    private let count: Count

    private init?() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        func function<T>(_ symbol: String, _ type: T.Type) -> T? {
            dlsym(library, symbol).map { unsafeBitCast($0, to: type) }
        }
        guard let copyChannels = function("IOReportCopyChannelsInGroup", Channels.self),
              let subscribe = function("IOReportCreateSubscription", Subscribe.self),
              let samples = function("IOReportCreateSamples", Samples.self),
              let name = function("IOReportChannelGetChannelName", Label.self),
              let unit = function("IOReportChannelGetUnitLabel", Label.self),
              let count = function("IOReportSimpleGetIntegerValue", Count.self),
              let channels = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
            dlclose(library)
            return nil
        }
        self.channels = channels
        self.subscribe = subscribe
        self.samples = samples
        self.name = name
        self.unit = unit
        self.count = count
    }

    struct Subscription {
        let handle: CFTypeRef
        let channels: CFDictionary
    }

    func openSubscription() -> Subscription? {
        var accepted: Unmanaged<CFDictionary>?
        let subscription = subscribe(nil, channels, &accepted, 0, nil)?.takeRetainedValue()
        guard let channels = accepted?.takeRetainedValue(), let subscription else { return nil }
        return Subscription(handle: subscription, channels: channels)
    }

    func sample(_ subscription: Subscription) -> GPUEnergyReading? {
        guard let report = samples(subscription.handle, subscription.channels, nil)?.takeRetainedValue() as NSDictionary?,
              let entries = report["IOReportChannels"] as? NSArray else { return nil }
        var reading: GPUEnergyReading?
        for row in entries {
            // The native accessor caches metadata in the original mutable dictionary.
            // Bridging the entries through Swift dictionaries would make them immutable.
            guard CFGetTypeID(row as CFTypeRef) == CFDictionaryGetTypeID() else { continue }
            let channel = row as! CFDictionary
            guard name(channel)?.takeUnretainedValue() as String? == "GPU Energy" else { continue }
            let scale: Double
            switch unit(channel)?.takeUnretainedValue() as String? {
            case "nJ": scale = 1e-9
            case "uJ", "µJ": scale = 1e-6
            case "mJ": scale = 1e-3
            case "J": scale = 1
            default: return nil
            }
            let ticks = count(channel, nil)
            guard ticks >= 0, reading == nil else { return nil }
            reading = GPUEnergyReading(ticks: ticks, joulesPerTick: scale, time: ProcessInfo.processInfo.systemUptime)
        }
        return reading
    }
}
