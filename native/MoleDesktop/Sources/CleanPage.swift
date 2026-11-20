import SwiftUI

struct CleanPage: View {
    @ObservedObject var model: PreviewModel
    let analyze: (URL) -> Void
    @State private var showingReport = false
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.locale) private var locale
    var body: some View {
        let _ = locale
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScanHero(model: model) { showingReport = true }
                        .frame(height: max(243, min(370, viewport.size.height - 283)))
                    if let message = model.message { Feedback(message: message) }
                    HStack(alignment: .top, spacing: 16) {
                        CapacityCard(volume: model.volume)
                        LocationCard(analyze: analyze)
                    }
                }
                .frame(maxWidth: 1250)
                .padding(26)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { model.refreshVolume() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refreshVolume() }
        }
        .sheet(isPresented: $showingReport) {
            if let report = model.report {
                ReportSheet(heading: model.didClean ? ReportText("清理执行记录", "Cleanup log") : ReportText("清理预览明细", "Cleanup preview"), report: report,
                            cleanTiming: report.canApplyClean ? { model.cleanTimingText } : nil,
                            confirmedClean: report.canApplyClean ? {
                                showingReport = false
                                model.applyAfterConfirmation()
                            } : nil)
            }
        }
    }
}

private struct ScanHero: View {
    @ObservedObject var model: PreviewModel
    let review: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        if model.applying { return tr("正在清理磁盘", "Cleaning up") }
        if model.running { return tr("正在扫描磁盘", "Scanning your Mac") }
        if model.didClean { return tr("清理已完成", "Cleanup complete") }
        return model.report == nil ? tr("空间清理", "Disk cleanup") : tr("扫描已完成", "Scan complete")
    }

    private var detail: String {
        if model.running {
            if !model.stage.isEmpty { return tr("当前项目 · ", "Checking · ") + model.stage }
            return model.applying ? tr("引擎正在重新核对候选项目和保护规则。", "Reviewing eligible items and protection rules…") : tr("正在准备并检查本机项目…", "Checking files on this Mac…")
        }
        return model.report?.summary ?? tr("检查缓存、日志和卸载残留，审阅后再清理。", "Review caches, logs, and leftover app files before cleaning.")
    }

    @ViewBuilder private var timingInfo: some View {
        if model.running {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let elapsed = model.elapsed
                let estimate = model.activeEstimate
                timingLines(estimate.remaining(elapsed: elapsed),
                            tr("已用 ", "Elapsed ") + Self.clock(elapsed) + " · " + estimate.basis)
            }
        } else if let start = model.startedAt, let end = model.finishedAt, let report = model.report {
            let duration = Self.clock(end.timeIntervalSince(start))
            if report.canApplyClean {
                timingLines(model.cleanTimingText, tr("扫描用时 ", "Scan time · ") + duration + tr(" · 等待确认", " · Awaiting confirmation"))
            } else {
                timingLines((model.didClean ? tr("清理用时 ", "Cleanup time · ") : tr("扫描用时 ", "Scan time · ")) + duration)
            }
        } else {
            let scan = model.scanEstimate
            let clean = model.cleanEstimate
            let cleanLine = tr("确认后清理约 ", "Cleanup after review · ") + clean.rangeText
            timingLines(tr("扫描约 ", "Estimated scan · ") + scan.rangeText + " · " + scan.basis,
                        scan.basis == clean.basis ? cleanLine : cleanLine + " · " + clean.basis)
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, Int(seconds))).formatted(.time(pattern: .minuteSecond))
    }

    private func timingLines(_ primary: String, _ secondary: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "clock").font(.system(size: 12, weight: .medium))
                .foregroundStyle(StrataColor.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(primary).font(.system(size: 13, weight: .medium)).foregroundStyle(StrataColor.ink)
                if let secondary { Text(secondary).font(.system(size: 12)).foregroundStyle(StrataColor.muted) }
            }.monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
    }

    @Environment(\.locale) private var locale
    var body: some View {
        let _ = locale
        GeometryReader { geo in
            let inset: CGFloat = geo.size.width < 820 ? 25 : 36
            ZStack(alignment: .leading) {
                LinearGradient(colors: [Color(red: 0.129, green: 0.153, blue: 0.164),
                                        Color(red: 0.085, green: 0.098, blue: 0.111),
                                        Color(red: 0.048, green: 0.055, blue: 0.064)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                StarAtlas()
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.system(size: geo.size.width < 820 ? 32 : 41, weight: .semibold))
                            .foregroundStyle(StrataColor.ink)
                        Text(detail).font(.system(size: 14)).lineSpacing(5)
                            .foregroundStyle(StrataColor.muted)
                            .textSelection(.enabled).padding(.top, 10)
                            .fixedSize(horizontal: false, vertical: true)
                        timingInfo.padding(.top, 16)
                        HStack(spacing: 10) {
                            if model.running {
                                Button(model.applying ? tr("停止清理", "Stop cleanup") : tr("取消扫描", "Cancel scan"), action: model.cancel)
                                    .buttonStyle(ActionStyle())

                            } else if model.report != nil {
                                Button(action: review) { Label(tr("查看明细", "Review results"), systemImage: "list.bullet.rectangle") }
                                    .buttonStyle(ActionStyle(isPrimary: true))
                                Button(action: model.start) { Image(systemName: "arrow.clockwise") }
                                    .buttonStyle(ActionStyle()).help(tr("重新扫描", "Scan again")).accessibilityLabel(tr("重新扫描", "Scan again"))
                            } else {
                                Button(action: model.start) {
                                    HStack(spacing: 10) { Text(tr("开始扫描", "Start scan")); Image(systemName: "arrow.right") }
                                }.buttonStyle(ActionStyle(isPrimary: true))
                            }
                        }.padding(.top, 16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    OrbitArtwork(isScanning: model.running)
                        .frame(width: geo.size.width * 0.45, height: min(292, geo.size.height - 22))
                }.padding(.leading, inset).padding(.trailing, 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.16), StrataColor.border.opacity(0.65)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.running)
    }
}

private struct StarAtlas: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 125
            func random() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 32) / Double(UInt32.max)
            }
            for _ in 0..<160 {
                let x = random() * size.width
                let y = random() * size.height
                let r = 0.45 + random() * 1.0
                let opacity = (0.1 + random() * 0.40) * (0.18 + 0.82 * x / max(1, size.width))
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                             with: .color(.white.opacity(opacity)))
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}

private struct CapacityCard: View {
    let volume: VolumeReading?
    @Environment(\.locale) private var locale
    var body: some View {
        let _ = locale
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                Label(tr("本机存储", "Local storage"), systemImage: "internaldrive")
                    .font(.system(size: 16, weight: .semibold))
                if let volume {
                    Text(volume.volume).font(.system(size: 12)).foregroundStyle(StrataColor.muted).padding(.top, 4)
                    Spacer(minLength: 12)
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().stroke(StrataColor.border, lineWidth: 8)
                            Circle().trim(from: 0, to: volume.fraction)
                                .stroke(AngularGradient(colors: [StrataColor.accent, StrataColor.mint], center: .center),
                                        style: StrokeStyle(lineWidth: 8, lineCap: .butt))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 1) {
                                Text(volume.fraction.formatted(.percent.precision(.fractionLength(0))))
                                    .font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text(tr("已用", "Used")).font(.system(size: 10)).foregroundStyle(StrataColor.muted)
                            }
                        }.frame(width: 87, height: 87)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("可用空间", "Available")).font(.system(size: 12)).foregroundStyle(StrataColor.muted)
                            Text(storageSize(volume.free)).font(.system(size: 25, weight: .semibold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.7).monospacedDigit()
                        }
                    }.padding(.vertical, 6)
                    Spacer(minLength: 14)
                    Divider()
                    HStack {
                        Text(tr("已用 ", "Used · ") + storageSize(volume.used)); Spacer()
                        Text(tr("共 ", "Total · ") + storageSize(volume.capacity))
                    }.font(.system(size: 11)).foregroundStyle(StrataColor.muted).padding(.top, 10)
                } else {
                    Spacer()
                    Text(tr("暂时无法读取当前卷的容量。", "Storage capacity is unavailable.")).font(.callout).foregroundStyle(StrataColor.muted)
                    Spacer()
                }
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 175)
        }
    }
}

private struct LocationCard: View {
    let analyze: (URL) -> Void
    private let home = FileManager.default.homeDirectoryForCurrentUser
    @Environment(\.locale) private var locale
    var body: some View {
        let _ = locale
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                Label(tr("按位置分析", "Explore by location"), systemImage: "chart.bar.xaxis")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 6)
                row(tr("用户缓存", "User caches"), url: home.appendingPathComponent("Library/Caches"), icon: "archivebox",
                    color: StrataColor.muted)
                Divider()
                row(tr("下载", "Downloads"), url: home.appendingPathComponent("Downloads"), icon: "arrow.down.to.line",
                    color: StrataColor.muted)
                Divider()
                row(tr("应用程序", "Applications"), url: URL(fileURLWithPath: "/Applications"), icon: "square.grid.2x2",
                    color: StrataColor.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 175)
        }
    }

    private func row(_ name: String, url: URL, icon: String, color: Color) -> some View {
        Button { analyze(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                    .frame(width: 29, height: 29).foregroundStyle(color)
                    .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .medium))
                    Text(verbatim: (url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(StrataColor.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(StrataColor.muted)
            }.padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(LocationButtonStyle(tint: color)).help(tr("分析 ", "Analyze ") + url.path)
    }
}

private struct LocationButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HighlightedRow(label: configuration.label, tint: tint, pressed: configuration.isPressed)
    }

    private struct HighlightedRow: View {
        let label: ButtonStyleConfiguration.Label
        let tint: Color
        let pressed: Bool
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            label.background {
                RoundedRectangle(cornerRadius: 6).fill(tint.opacity(pressed ? 0.16 : hovered ? 0.08 : 0))
                    .padding(.horizontal, -5)
            }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: hovered)
        }
    }
}
