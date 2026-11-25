import SwiftUI

private struct MenuViewportSize: NSViewRepresentable {
    let resize: (CGSize) -> Void

    final class Reader: NSView {
        var resize: ((CGSize) -> Void)?

        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            guard changed else { return }
            // Resizing the NSPopover starts another AppKit layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.frame.size == newSize else { return }
                self.resize?(newSize)
            }
        }
    }

    func makeNSView(context: Context) -> Reader {
        let reader = Reader()
        reader.resize = resize
        return reader
    }

    func updateNSView(_ reader: Reader, context: Context) { reader.resize = resize }
}

struct MenuViewport<Content: View>: View {
    let maximumHeight: CGFloat
    let resize: (CGSize) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView { content() }
            .frame(maxHeight: maximumHeight)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 352)
            .background(MenuViewportSize(resize: resize))
    }
}

struct MenuDashboard: View {
    let readings: StatusReadings
    let onOpenStatus: () -> Void
    let onQuit: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            overview
            Grid(horizontalSpacing: 7, verticalSpacing: 7) {
                GridRow { cpu; gpu }
                GridRow { memory; disk }
                GridRow { network; fan }
            }
            battery
            FineTuneCard().menuSurface()
            HStack {
                Spacer()
                Button(action: onQuit) {
                    Label(tr("退出 Strata", "Quit Strata"), systemImage: "power")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StrataColor.muted)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .padding(10)
        .foregroundStyle(StrataColor.ink)
        .frame(width: 352)
        .preferredColorScheme(.dark)
    }

    private var overview: some View {
        let health = readings.health
        let status = health?.label ?? (readings.warmingUp ? tr("正在采样…", "Sampling…") : tr("暂无评分", "Score unavailable"))
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        let chip = readings.chip.replacingOccurrences(of: "Apple ", with: "")
        return Button(action: onOpenStatus) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(amber)
                    Text(health.map { String($0.score) } ?? "—")
                        .font(.system(size: 33, weight: .bold, design: .rounded))
                        .tracking(-1).monospacedDigit()
                    Text(status)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(StrataColor.muted)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(StrataColor.muted)
                }
                HStack(spacing: 4) {
                    chipLabel(chip)
                    chipLabel(memorySize(ProcessInfo.processInfo.physicalMemory))
                    chipLabel(os)
                    if readings.uptime != nil {
                        chipLabel(tr("已运行 ", "Up ") + statusUptime(readings.uptime))
                    }
                }
            }
            .padding(.horizontal, 3).padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("打开完整系统状态", "Open full system status"))
        .accessibilityLabel(tr("系统健康，", "System health, ") + (health.map { "\($0.score), " } ?? "") + status)
        .accessibilityValue([chip, memorySize(ProcessInfo.processInfo.physicalMemory), os,
                             readings.uptime.map { tr("已运行 ", "Up ") + statusUptime($0) }].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(tr("打开完整系统状态", "Open full system status"))
        .accessibilityIdentifier("menu-open-status")
    }

    private func chipLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .foregroundStyle(StrataColor.muted).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
            .help(text)
    }

    private func temperature(_ value: Double?) -> String? {
        value.map { "\(Int($0.rounded()))°C" }
    }

    private func percent(_ fraction: Double?) -> String {
        fraction.map { String(Int(($0 * 100).rounded())) } ?? "—"
    }

    private var cpu: some View {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let load = readings.vitals.load.map { $0.formatted(.number.locale(locale).precision(.fractionLength(1))) }
        let detail = tr("\(cores) 核", "\(cores) cores") + (load.map { tr(" · 负载 ", " · Load ") + $0 } ?? "")
        return MenuMetric(title: "CPU", icon: "cpu", tint: jade, badge: temperature(readings.sensors.cpuCelsius),
                          value: percent(readings.cpu), unit: readings.cpu == nil ? "" : "%", detail: detail) {
            if readings.usageByCore.isEmpty {
                MetricTrace(points: readings.trend.points(for: \.cpu), color: jade)
            } else {
                GeometryReader { rect in
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(readings.usageByCore.indices, id: \.self) { index in
                            let fraction = readings.usageByCore[index]
                            RoundedRectangle(cornerRadius: 1.4)
                                .fill(fraction == nil ? Color.clear : jade)
                                .frame(height: max(1, rect.size.height * (fraction ?? 0)))
                        }
                    }.frame(maxHeight: .infinity, alignment: .bottom)
                }.accessibilityHidden(true)
            }
        }
    }

    private var gpu: some View {
        let sensor = readings.sensors
        let details = [sensor.gpuCores.map { tr("\($0) 核", "\($0) cores") }, readings.gpuWatts.map(powerReading)].compactMap { $0 }
        let fallback = sensor.gpuPercent.map { $0 < 10 ? tr("空闲", "Idle") : tr("运行中", "Active") } ?? tr("使用率不可用", "Usage unavailable")
        return MenuMetric(title: "GPU", icon: "display", tint: amber, badge: temperature(sensor.gpuCelsius),
                          value: sensor.gpuPercent.map { String(Int($0.rounded())) } ?? "—",
                          unit: sensor.gpuPercent == nil ? "" : "%",
                          detail: details.isEmpty ? fallback : details.joined(separator: " · ")) {
            MetricTrace(points: readings.trend.points(for: \.gpu), color: amber)
        }
    }

    private var memory: some View {
        let value = readings.memory
        return MenuMetric(title: tr("内存", "Memory"), icon: "memorychip", tint: lilac, badge: readings.vitals.pressure?.label,
                          value: percent(value?.fraction), unit: value == nil ? "" : "%",
                          detail: value.map { memorySize($0.used) + " / " + memorySize($0.total) } ?? "—") {
            MetricTrace(points: readings.trend.points(for: \.memory), color: lilac)
        }
    }

    private var disk: some View {
        let disk = readings.disk
        let free = disk.map { storageSize(Int64(clamping: $0.total - $0.used)) }
        let detail = readings.diskIO.map { tr("读取 ", "Read ") + statusRate($0.read) }
            ?? disk.map { tr("已用 ", "Used ") + storageSize(Int64(clamping: $0.used)) } ?? "—"
        return MenuMetric(title: tr("可用空间", "Free space"), icon: "internaldrive", tint: sky,
                          badge: disk.map { storageSize(Int64(clamping: $0.total)) }, value: free ?? "—", detail: detail) {
            MenuGauge(fraction: disk?.fraction, tint: sky)
                .accessibilityLabel(tr("磁盘已用比例", "Disk utilization"))
        }
    }

    private var network: some View {
        let history = readings.trend
        let peak = max(1, history.samples.filter { $0.interface == readings.link }.reduce(0.0) { max($0, $1.up ?? 0, $1.down ?? 0) })
        return MenuMetric(title: tr("网络", "Network"), icon: "network", tint: jade, badge: readings.linkType ?? readings.link,
                          value: statusRate(readings.throughput?.down),
                          detail: tr("↑ 上传 ", "↑ Upload ") + statusRate(readings.throughput?.up)) {
            ZStack {
                MetricTrace(points: history.points(for: \.down, upperBound: peak, sameLink: true), color: sky)
                MetricTrace(points: history.points(for: \.up, upperBound: peak, sameLink: true), color: jade, baseline: false)
            }
        }.accessibilityHint(tr("大号读数为下载速度", "The main reading is download speed"))
    }

    private var fan: some View {
        let sensor = readings.sensors
        let mode = sensor.fanAutomatic.map { $0 ? tr("自动调速", "Automatic control") : tr("手动调速", "Manual control") }
        let detail = sensor.fanRPM != nil ? (mode ?? tr("实测转速", "Measured speed"))
            : (sensor.fanCount == 0 ? tr("本机无内置风扇", "Fanless Mac") : tr("传感器不可用", "Sensor unavailable"))
        return MenuMetric(title: tr("风扇", "Fan"), icon: "fanblades", tint: amber,
                          badge: sensor.fanPercent.map { "\(Int($0.rounded()))%" },
                          value: sensor.fanRPM.map { Int($0.rounded()).formatted(.number.locale(locale)) } ?? "—",
                          unit: sensor.fanRPM == nil ? "" : "RPM", detail: detail) {
            MenuGauge(fraction: sensor.fanPercent.map { $0 / 100 }, tint: amber)
        }
    }

    private var battery: some View {
        let sensor = readings.sensors
        let charge = readings.battery.charge
        let health = sensor.batteryHealthPercent.map { tr("健康 \(Int($0.rounded()))%", "\(Int($0.rounded()))% health") }
        let cycles = sensor.batteryCycles.map { tr("\($0) 次循环", "\($0) cycles") }
        let time = sensor.batteryMinutes.flatMap { minutes -> String? in
            let duration = String(format: "%d:%02d", minutes / 60, minutes % 60)
            switch readings.battery.supply {
            case .charging: return tr("\(duration) 后充满", "\(duration) to full")
            case .battery: return tr("剩余 \(duration)", "\(duration) left")
            default: return nil
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                MenuMetricTitle(title: tr("电池", "Battery"), icon: "battery.75", tint: lime)
                if let cycles { Text(cycles).font(.system(size: 10)).foregroundStyle(StrataColor.muted) }
                Spacer()
                if let health { chipLabel(health) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if charge != nil {
                    Text(percent(charge) + "%").font(.system(size: 23, weight: .semibold, design: .rounded))
                }
                if let watts = sensor.batteryWatts {
                    Label(powerReading(abs(watts)), systemImage: "bolt.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(lime)
                        .help(tr("电池瞬时功率", "Instantaneous battery power"))
                }
                Spacer(minLength: 0)
                Text([readings.battery.supply.description, time].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(StrataColor.muted)
            }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .menuSurface()
    }

}

private struct MenuMetricTitle: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
            Text(title).foregroundStyle(StrataColor.muted)
        }.font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
    }
}

private struct MenuMetric<Visual: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let badge: String?
    let value: String
    var unit = ""
    let detail: String
    @ViewBuilder let visual: () -> Visual

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                MenuMetricTitle(title: title, icon: icon, tint: tint)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge).font(.system(size: 9, weight: .medium)).foregroundStyle(StrataColor.muted)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                        .help(badge)
                }
            }.frame(height: 14)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 23, weight: .semibold, design: .rounded))
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(StrataColor.muted)
                }
            }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.68)
            visual().frame(height: 15)
            Text(detail).font(.system(size: 10)).foregroundStyle(StrataColor.muted)
                .lineLimit(1).minimumScaleFactor(0.82).help(detail)
        }
        .menuSurface()
        .accessibilityElement(children: .combine)
    }
}

private struct MenuGauge: View {
    let fraction: Double?
    let tint: Color

    var body: some View {
        GeometryReader { rect in
            Capsule().fill(.white.opacity(0.065)).overlay(alignment: .leading) {
                if let fraction {
                    Capsule().fill(tint.opacity(0.85)).frame(width: rect.size.width * min(1, max(0, fraction)))
                }
            }.frame(height: 4).frame(maxHeight: .infinity)
        }
    }
}

private extension View {
    func menuSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return self.padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrataColor.panel, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.07), lineWidth: 0.7).allowsHitTesting(false))
    }
}
