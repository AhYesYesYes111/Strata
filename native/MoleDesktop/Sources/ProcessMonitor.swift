import AppKit
import Darwin
import SwiftUI

struct MonitorProcessID: Hashable {
    let pid: Int32
    let birth: String
}

struct ProcessReading: Identifiable {
    let id: MonitorProcessID
    let name: String
    let memory: Int64
    let isResidentSize: Bool
    let cpu: Double?
    let watts: Double?
}

struct ProcessCounters {
    let cpu: UInt64
    let energy: UInt64?
    let stamp: UInt64

    func rates(since last: Self?, nanosecondsPerTick: Double) -> (cpu: Double?, watts: Double?) {
        guard let last, stamp > last.stamp else { return (nil, nil) }
        let ticks = Double(stamp - last.stamp)
        let ns = ticks * nanosecondsPerTick
        guard ns > 0, ns <= 15_000_000_000 else { return (nil, nil) }
        let percent = cpu >= last.cpu ? Double(cpu - last.cpu) / ticks * 100 : nil
        var watts: Double?
        if let energy, let previous = last.energy, energy >= previous {
            watts = Double(energy - previous) / ns
        }
        return (percent, watts)
    }
}

actor ProcessSampler {
    private var previous: [MonitorProcessID: ProcessCounters] = [:]
    private let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func sample() throws -> [ProcessReading] {
        try Task.checkCancellation()
        let count = proc_listallpids(nil, 0)
        var ids = [Int32](repeating: 0, count: max(128, Int(count) + 64))
        let listed = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let stamp = mach_absolute_time()
        var next: [MonitorProcessID: ProcessCounters] = [:]
        var rows: [ProcessReading] = []
        var measured = Set<Int32>()
        var path = [CChar](repeating: 0, count: 4096)
        for pid in ids.prefix(max(0, Int(listed))) where pid > 0 {
            try Task.checkCancellation()
            var usage = rusage_info_v6()
            let flavor: Int32 = withUnsafeMutablePointer(to: &usage) { info in
                info.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buffer in
                    if proc_pid_rusage(pid, RUSAGE_INFO_V6, buffer) == 0 { return RUSAGE_INFO_V6 }
                    // Older kernels support the same prefix through ri_proc_start_abstime.
                    if errno == EINVAL, proc_pid_rusage(pid, RUSAGE_INFO_V0, buffer) == 0 { return RUSAGE_INFO_V0 }
                    return -1
                }
            }
            guard flavor >= 0, usage.ri_proc_start_abstime > 0 else { continue }
            let id = MonitorProcessID(pid: pid, birth: String(usage.ri_proc_start_abstime))
            let counters = ProcessCounters(cpu: usage.ri_user_time &+ usage.ri_system_time,
                                          energy: flavor == RUSAGE_INFO_V6 && usage.ri_energy_nj > 0 ? usage.ri_energy_nj : nil,
                                          stamp: stamp)
            let rates = counters.rates(since: previous[id], nanosecondsPerTick: nanosecondsPerTick)
            let name: String
            let pathSize = UInt32(path.count)
            if proc_pidpath(pid, &path, pathSize) > 0 {
                name = (String(cString: path) as NSString).lastPathComponent
            } else if proc_name(pid, &path, pathSize) > 0 {
                name = String(cString: path)
            } else {
                name = "PID " + String(pid)
            }
            next[id] = counters
            measured.insert(pid)
            rows.append(ProcessReading(id: id, name: name, memory: Int64(clamping: usage.ri_phys_footprint),
                                       isResidentSize: false, cpu: rates.cpu, watts: rates.watts))
        }
        // The system ps can report RSS and CPU for system services that deny libproc counters.
        if measured.count < Int(listed) || listed <= 0 {
            rows += try Self.systemRows(excluding: measured)
        }
        try Task.checkCancellation()
        previous = next
        return rows
    }

    private static func systemRows(excluding measured: Set<Int32>) throws -> [ProcessReading] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Aco", "pid=,rss=,pcpu=,lstart=,comm="]
        ps.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        ps.standardInput = FileHandle.nullDevice
        do { try ps.run() } catch { return [] }
        defer {
            if ps.isRunning { ps.terminate() }
            try? pipe.fileHandleForReading.close()
        }
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let limit = ProcessInfo.processInfo.systemUptime + 1.5
        let fd = pipe.fileHandleForReading.fileDescriptor
        var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var complete = false
        while ProcessInfo.processInfo.systemUptime < limit && bytes.count < 8_388_608 {
            try Task.checkCancellation()
            let ready = Darwin.poll(&pending, 1, 35)
            if ready < 0 && errno != EINTR { return [] }
            if ready <= 0 { continue }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count == 0 { complete = true }
            guard count > 0 else { break }
            bytes.append(contentsOf: chunk.prefix(count))
        }
        guard complete else { return [] }
        while ps.isRunning && ProcessInfo.processInfo.systemUptime < limit {
            try Task.checkCancellation()
            usleep(2_000)
        }
        guard !ps.isRunning, ps.terminationStatus == 0 else { return [] }
        return String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 8, whereSeparator: \.isWhitespace)
            guard fields.count == 9, let pid = Int32(fields[0]), pid > 0,
                  pid != ps.processIdentifier, !measured.contains(pid),
                  let kib = Int64(fields[1]), kib >= 0, kib <= Int64.max / 1024 else { return nil }
            let id = MonitorProcessID(pid: pid, birth: fields[3...7].joined(separator: " "))
            return ProcessReading(id: id, name: String(fields[8]).trimmingCharacters(in: .whitespaces),
                                  memory: kib * 1024, isResidentSize: true, cpu: Double(fields[2]), watts: nil)
        }
    }
}

private enum ProcessColumn {
    case name, memory, cpu, watts, pid
    var title: String {
        switch self {
        case .name: return tr("进程", "Process")
        case .cpu: return "CPU"
        case .memory: return tr("内存", "Memory")
        case .watts: return tr("功耗", "Power")
        case .pid: return "PID"
        }
    }
}

struct ProcessMonitorView: View {
    let rows: [ProcessReading]
    let didSample: Bool

    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var sort: ProcessColumn = .memory
    @State private var ascending = false

    private var filtered: [ProcessReading] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || String($0.id.pid).contains(term) }
            .sorted { l, r in
                switch sort {
                case .name:
                    let result = l.name.localizedStandardCompare(r.name)
                    if result != .orderedSame { return ascending ? result == .orderedAscending : result == .orderedDescending }
                case .pid: return ascending ? l.id.pid < r.id.pid : l.id.pid > r.id.pid
                case .memory:
                    if l.memory != r.memory { return ascending ? l.memory < r.memory : l.memory > r.memory }
                case .cpu, .watts:
                    let a = sort == .cpu ? l.cpu : l.watts
                    let b = sort == .cpu ? r.cpu : r.watts
                    if a != b {
                        guard let a else { return false }
                        guard let b else { return true }
                        return ascending ? a < b : a > b
                    }
                }
                return l.id.pid < r.id.pid
            }
    }

    var body: some View {
        let _ = locale
        let visible = filtered
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(tr("进程", "Processes")).font(.headline)
                Text("\(visible.count)").font(.caption.monospacedDigit()).foregroundStyle(StrataColor.muted)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(StrataColor.muted)
                    TextField(tr("名称或 PID", "Name or PID"), text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel(tr("清除搜索", "Clear search"))
                    }
                }.font(.callout).padding(.horizontal, 9).padding(.vertical, 5)
                    .frame(width: 170)
                    .background(StrataColor.paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
            }.padding(.horizontal, 16).padding(.vertical, 9)
            Divider()
            HStack(spacing: 12) {
                column(.name).frame(maxWidth: .infinity, alignment: .leading)
                column(.memory).frame(width: 90, alignment: .trailing)
                    .help(tr("物理内存占用；仅有驻留内存时标记 RSS。", "Physical footprint. RSS marks a resident-size reading."))
                column(.cpu).frame(width: 70, alignment: .trailing)
                    .help(tr("100% 对应一个 CPU 核心。", "100% represents one CPU core."))
                column(.watts).frame(width: 72, alignment: .trailing)
                    .help(tr("按内核归属的 CPU 能量估算平均功率。", "Average power from the kernel’s CPU energy attribution."))
                column(.pid).frame(width: 55, alignment: .trailing)
            }.font(.caption.weight(.semibold)).foregroundStyle(StrataColor.muted)
                .padding(.horizontal, 16).padding(.vertical, 6)
            Divider()
            if visible.isEmpty {
                Text(!didSample ? tr("正在读取进程…", "Reading processes…") :
                        (rows.isEmpty ? tr("无法读取进程信息", "Process information unavailable") :
                            tr("没有匹配的进程", "No matching processes")))
                    .font(.callout).foregroundStyle(StrataColor.muted)
                    .frame(maxWidth: .infinity).frame(height: 104)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { row in
                            ProcessMonitorRow(reading: row)
                            Divider().opacity(0.45)
                        }
                    }
                }.frame(height: 233)
            }
        }
        .background(StrataColor.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StrataColor.border).allowsHitTesting(false))

    }

    private func column(_ column: ProcessColumn) -> some View {
        Button {
            if sort == column { ascending.toggle() }
            else { sort = column; ascending = column == .name || column == .pid }
        } label: {
            HStack(spacing: 4) {
                Text(column.title)
                if sort == column {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct ProcessMonitorRow: View {
    let reading: ProcessReading
    @State private var icon: NSImage?
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 19, height: 19) }
                else { Image(systemName: "app.dashed").frame(width: 19).foregroundStyle(StrataColor.muted) }
                Text(verbatim: reading.name).lineLimit(1).truncationMode(.middle)
                    .help(reading.name)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if reading.isResidentSize { Text("RSS").font(.system(size: 8)).foregroundStyle(StrataColor.muted) }
                Text(storageSize(reading.memory))
            }.frame(width: 90, alignment: .trailing)
            Text(reading.cpu.map { $0.formatted(.number.locale(locale).precision(.fractionLength(1))) + "%" } ?? "—")
                .frame(width: 70, alignment: .trailing)
            Text(reading.watts.map(powerReading) ?? "—")
                .frame(width: 72, alignment: .trailing)
            Text(verbatim: String(reading.id.pid)).foregroundStyle(StrataColor.muted)
                .frame(width: 55, alignment: .trailing)
        }
        .font(.callout).monospacedDigit().lineLimit(1)
        .padding(.horizontal, 16).frame(height: 29)
        .onAppear {
            // Helpers often lack their own workspace icon. Use the enclosing app’s icon.
            var path = [CChar](repeating: 0, count: 4096)
            let capacity = UInt32(path.count)
            if proc_pidpath(reading.id.pid, &path, capacity) > 0 {
                let executable = String(cString: path)
                if let bundle = executable.range(of: ".app/Contents/", options: .caseInsensitive) {
                    let appPath = String(executable[..<bundle.lowerBound]) + String(executable[bundle].prefix(4))
                    icon = NSWorkspace.shared.icon(forFile: appPath)
                    return
                }
            }
            icon = NSRunningApplication(processIdentifier: reading.id.pid)?.icon
        }
    }
}
