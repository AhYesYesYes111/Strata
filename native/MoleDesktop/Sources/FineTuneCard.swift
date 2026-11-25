import SwiftUI

struct FineTuneCard: View {
    @ObservedObject private var audio = FineTuneConnection.shared
    @State private var showInputs = false
    @State private var showInactive = false

    private var kind: FineTuneKind { showInputs ? .input : .output }
    private var devices: [FineTuneDevice] { showInputs ? audio.inputs : audio.outputs }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if audio.connected {
                    Menu {
                        Button(action: audio.openMixer) {
                            Label(tr("打开完整混音器", "Open Full Mixer"), systemImage: "slider.horizontal.3")
                        }
                        if let enabled = audio.outputPriorityEnabled {
                            Button(action: audio.openEditor) {
                                Label(tr("管理设备与应用…", "Manage Devices and Apps…"), systemImage: "pencil")
                            }
                            Divider()
                            Toggle(tr("使用输出设备优先级", "Use Output Device Priority"),
                                   isOn: Binding(get: { enabled }, set: audio.setOutputPriority))
                        }
                    } label: {
                        mixerTitle.frame(minHeight: 22)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                    .accessibilityLabel(tr("FineTune 混音器和设备选项", "FineTune mixer and device options"))
                    .help(tr("打开混音器、管理设备与应用", "Open the mixer or manage devices and apps"))
                } else {
                    mixerTitle
                }
                Spacer(minLength: 0)
                if audio.connected {
                    Picker(tr("设备类型", "Device type"), selection: $showInputs) {
                        Text(tr("输出", "Output")).tag(false)
                        Text(tr("输入", "Input")).tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                    .fixedSize()
                    Button(action: audio.openSettings) {
                        Label(tr("设置", "Settings"), systemImage: "gearshape")
                            .font(.system(size: 11, weight: .medium))
                            .frame(minHeight: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).fixedSize()
                    .accessibilityLabel(tr("FineTune 设置", "FineTune settings"))
                    .help(tr("打开 FineTune 设置", "Open FineTune settings"))
                }
            }
            if audio.connected {
                if devices.isEmpty {
                    note(showInputs ? tr("没有输入设备", "No input devices") : tr("没有输出设备", "No output devices"))
                } else {
                    ForEach(devices) { device in
                        deviceRow(device)
                    }
                }
                Divider()
                Text(tr("应用音量", "App volume")).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrataColor.muted)
                if !audio.appAudioAuthorized {
                    Button(action: audio.openMixer) {
                        Label(tr("打开混音器，授权 FineTune 控制应用音频", "Open the mixer to grant FineTune audio access"),
                              systemImage: "arrow.up.right.square")
                    }
                    .font(.system(size: 11)).foregroundStyle(sky).buttonStyle(.plain)
                } else if audio.apps.isEmpty {
                    note(tr("当前没有播放音频的应用", "No apps playing audio"))
                } else {
                    ForEach(audio.apps.filter { $0.isActive != false }) { app in
                        appRow(app)
                    }
                    let inactive = audio.apps.filter { $0.isActive == false }
                    if !inactive.isEmpty {
                        DisclosureGroup(isExpanded: $showInactive) {
                            VStack(spacing: 6) {
                                ForEach(inactive) { app in appRow(app) }
                            }
                        } label: {
                            Text(tr("已置顶 · \(inactive.count) 个未播放", "Pinned · \(inactive.count) not playing"))
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(StrataColor.muted)
                        }.controlSize(.small)
                    }
                }
            } else {
                note(audio.connectionMessage)
                Button(audio.launchTitle, action: audio.launch)
                    .controlSize(.small)
                    .disabled(!audio.canLaunch)
            }
        }
        .accessibilityIdentifier("menu-finetune")
    }

    private var mixerTitle: some View {
        Label("FineTune", systemImage: "waveform")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .semibold))
    }

    private func deviceRow(_ device: FineTuneDevice) -> some View {
        let selection = device.isDefault ? tr("默认设备", "Default device") : tr("设为默认设备", "Set as default device")
        return HStack(spacing: 5) {
            Button {
                if !device.isDefault { audio.setDefault(kind: kind, id: device.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: device.isDefault ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(device.isDefault ? sky : StrataColor.muted)
                    Text(device.name).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .contentShape(Rectangle())
            }
            .font(.system(size: 11, weight: device.isDefault ? .semibold : .regular))
            .buttonStyle(.plain)
            .help(device.name + " · " + selection)
            .accessibilityLabel(device.name).accessibilityHint(selection)
            .accessibilityAddTraits(device.isDefault ? .isSelected : [])
            volumeControls(name: device.name, id: device.id, kind: kind, volume: device.volume,
                           muted: device.muted, canSetVolume: device.canSetVolume, canMute: device.canMute)
        }
    }

    private func appRow(_ app: FineTuneAudioApp) -> some View {
        let pinned = app.pinned == true
        let active = app.isActive != false
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                HStack(spacing: 4) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9))
                            .foregroundStyle(StrataColor.muted).accessibilityHidden(true)
                    }
                    Text(app.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(active ? StrataColor.ink : StrataColor.muted)
                    if let boost = app.boost, boost > 1 {
                        Text("\(boost)×")
                            .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(sky).fixedSize()
                            .help(tr("音量增益 \(boost) 倍", "\(boost)× volume boost"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityValue([pinned ? tr("已置顶", "Pinned") : nil,
                                     active ? nil : tr("未在播放", "Not playing")].compactMap { $0 }.joined(separator: ", "))
                .help(active ? app.name : app.name + " · " + tr("未在播放", "Not playing"))
                if app.boost != nil || app.eqEnabled != nil || app.pinned != nil {
                    appOptions(app)
                }
                volumeControls(name: app.name, id: app.id, kind: .app, volume: app.volume,
                               muted: app.muted, canSetVolume: true, canMute: true)
            }
            outputSelector(app)
        }
    }

    private func appOptions(_ app: FineTuneAudioApp) -> some View {
        let title = app.name + " · " + tr("音频选项", "Audio options")
        return Menu {
            if let boost = app.boost {
                Menu(tr("音量增益", "Volume boost") + " · \(boost)×") {
                    Picker(tr("音量增益", "Volume boost"), selection: Binding(get: { boost }, set: {
                        audio.setBoost(appID: app.id, multiplier: $0)
                    })) {
                        ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) }
                    }.pickerStyle(.inline).labelsHidden()
                }
            }
            if let eqEnabled = app.eqEnabled {
                Menu(tr("均衡器", "Equalizer")) {
                    Toggle(tr("启用均衡器", "Enable equalizer"), isOn: Binding(get: { eqEnabled }, set: {
                        audio.setEQEnabled(appID: app.id, enabled: $0)
                    }))
                    Button(tr("编辑频段与预设…", "Edit Bands and Presets…")) { audio.openAppEQ(appID: app.id) }
                }
            }
            if let pinned = app.pinned {
                Toggle(tr("置顶应用", "Pin app"), isOn: Binding(get: { pinned }, set: {
                    audio.setPinned(appID: app.id, pinned: $0)
                }))
            }
        } label: {
            menuIcon("slider.horizontal.3")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(title).help(title)
    }

    private func outputSelector(_ app: FineTuneAudioApp) -> some View {
        let follow = tr("跟随系统输出", "Follow system output")
        let selected = app.selectedDeviceIDs ?? []
        let route: String
        var multiDetail: String?
        if app.isMultiDevice, app.selectedDeviceIDs != nil {
            let names = audio.outputs.filter { selected.contains($0.id) }.map(\.name)
            if let first = names.first {
                route = names.count > 1 ? first + " +\(names.count - 1)" : first
                multiDetail = tr("多设备输出", "Multiple outputs") + " · " + names.joined(separator: " + ")
            } else {
                route = tr("未选择可见输出", "No visible output selected")
            }
        } else if app.isMultiDevice {
            route = tr("多个输出设备", "Multiple outputs")
        } else if let id = app.deviceID {
            route = audio.outputs.first { $0.id == id }?.name ?? tr("设备已隐藏或未连接", "Device hidden or disconnected")
        } else if let system = audio.outputs.first(where: \.isDefault) {
            route = tr("跟随系统", "System default") + " · " + system.name
        } else {
            route = follow
        }

        let title = app.name + " · " + tr("输出设备", "Output device")
        return HStack(spacing: 0) {
            Menu {
                routeButton(follow, deviceID: nil, app: app)
                ForEach(audio.outputs) { output in
                    routeButton(output.name, deviceID: output.id, app: app)
                }
                if app.selectedDeviceIDs != nil && !audio.outputs.isEmpty {
                    Divider()
                    Menu(tr("多设备同时播放", "Play on multiple devices")) {
                        ForEach(audio.outputs) { output in
                            multiRouteToggle(output, app: app, selected: selected)
                        }
                    }
                }
            } label: {
                Label(route, systemImage: app.isMultiDevice ? "hifispeaker.2" : "speaker.wave.2")
                    .lineLimit(1).truncationMode(.tail)
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).controlSize(.small)
            .foregroundStyle(StrataColor.muted)
            .accessibilityLabel(title).accessibilityValue(multiDetail ?? route)
            .help(title + " · " + (multiDetail ?? route))
            Spacer(minLength: 0)
        }
    }

    private func multiRouteToggle(_ output: FineTuneDevice, app: FineTuneAudioApp, selected: [String]) -> some View {
        let currentID = app.deviceID ?? audio.outputs.first(where: \.isDefault)?.id
        let seed = app.isMultiDevice ? selected : [currentID].compactMap { $0 }
        let current = Set(seed).intersection(audio.outputs.map(\.id))
        let enabled = current.contains(output.id)
        return Toggle(output.name, isOn: Binding(get: { enabled }, set: { include in
            var next = current
            if include { next.insert(output.id) } else { next.remove(output.id) }
            audio.setRoutes(appID: app.id, deviceIDs: next.sorted())
        }))
    }

    private func routeButton(_ name: String, deviceID: String?, app: FineTuneAudioApp) -> some View {
        Toggle(name, isOn: Binding(get: { !app.isMultiDevice && app.deviceID == deviceID }, set: { _ in
            audio.setRoute(appID: app.id, deviceID: deviceID)
        }))
    }

    private func volumeControls(name: String, id: String, kind: FineTuneKind, volume: Double,
                                muted: Bool, canSetVolume: Bool, canMute: Bool) -> some View {
        let muteAction = muted ? tr("取消静音", "Unmute") : tr("静音", "Mute")
        let muteSymbol = kind == .input
            ? (muted ? "mic.slash.fill" : "mic.fill")
            : (muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        return HStack(spacing: 4) {
            iconButton(muteSymbol, muteAction + " · " + name) {
                audio.setMute(!muted, kind: kind, id: id)
            }.disabled(!canMute)
            if canSetVolume {
                MixerVolume(value: volume, name: name) { audio.setVolume($0, kind: kind, id: id) }
            } else {
                Text(tr("固定音量", "Fixed volume"))
                    .font(.system(size: 10)).foregroundStyle(StrataColor.muted)
                    .frame(width: 112, alignment: .trailing)
            }
        }
    }

    private func note(_ title: String) -> some View {
        Text(title).font(.system(size: 11)).foregroundStyle(StrataColor.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func menuIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            .frame(width: 22, height: 22).contentShape(Rectangle())
    }

    private func iconButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).help(title)
    }
}

private struct MixerVolume: View {
    let value: Double
    let name: String
    let change: (Double) -> Void
    @State private var dragValue: Double?
    @State private var hovering = false

    private var slider: Binding<Double> {
        Binding(get: { dragValue ?? value }, set: { newValue in
            let rounded = (newValue * 100).rounded() / 100
            if let previous = dragValue {
                dragValue = newValue
                guard (previous * 100).rounded() != (newValue * 100).rounded() else { return }
            }
            change(rounded)
        })
    }

    var body: some View {
        HStack(spacing: 4) {
            Slider(value: slider, in: 0...1, onEditingChanged: { editing in
                dragValue = editing ? value : nil
            })
                .controlSize(.small).tint(sky)
                .background(VolumeWheelTarget(hovered: hovering && dragValue == nil, volume: value, change: change))
                .onHover { hovering = $0 }
                .accessibilityLabel(name + " · " + tr("音量", "Volume"))
                .help(tr("滚轮微调音量", "Scroll to fine-tune volume"))
            Text((dragValue ?? value).formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(StrataColor.muted)
                .frame(width: 30, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .frame(width: 112)
    }
}
