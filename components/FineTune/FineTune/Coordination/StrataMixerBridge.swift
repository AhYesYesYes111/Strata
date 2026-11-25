// The two apps keep their own lifetimes and audio permissions. Strata owns the
// status item only while it renews its lease in this login session.
import AppKit
import AudioToolbox
import Combine

@MainActor
final class StrataMixerBridge: ObservableObject, MenuBarPopupControlling {
    static let openSettingsNotification = Notification.Name("FineTune.openSettingsFromStrata")
    private static let hostBundleID = "local.strata.DiskWorkspace"

    @Published var showMenuBarExtra = true

    private let engine: AudioEngine
    private let monitor: DeviceVolumeMonitor
    private let popupController: MenuBarPopupController
    private let popupVisibility: PopupVisibilityService
    private var host: UUID?
    private var hostPID: pid_t?
    private var hostExit: DispatchSourceProcess?
    private var subscribed = false
    private var originalVisibility = true
    private var expiry: Task<Void, Never>?
    private var mixerPresentation: Task<Void, Never>?
    private var server: StrataMixerServer?
    private weak var statusItem: NSStatusItem?

    init(engine: AudioEngine, monitor: DeviceVolumeMonitor, popupController: MenuBarPopupController, popupVisibility: PopupVisibilityService) {
        self.engine = engine
        self.monitor = monitor
        self.popupController = popupController
        self.popupVisibility = popupVisibility
        server = StrataMixerServer { [weak self] data, peerPID, deadline in
            DispatchQueue.main.sync {
                guard let self, self.server != nil, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                return self.receive(data, peerPID: peerPID)
            }
        }
    }

    func stop() {
        server = nil
        detach()
    }

    private struct Request: Decodable {
        let action: String
        let clientID: UUID
        let clientPID: Int32
        let targetPID: Int32
        let id: String?
        let kind: String?
        let value: Double?
        let muted: Bool?
        let deviceID: String?
        let selectedDeviceIDs: [String]?
        let boost: Int?
        let enabled: Bool?
    }

    private func receive(_ data: Data, peerPID: pid_t) -> Data? {
        guard let request = try? JSONDecoder().decode(Request.self, from: data),
              request.clientPID == peerPID,
              request.targetPID == ProcessInfo.processInfo.processIdentifier,
              NSRunningApplication(processIdentifier: request.clientPID)?.bundleIdentifier == Self.hostBundleID
        else { return nil }

        if request.action == "presence" || request.action == "subscribe" {
            if let host, host != request.clientID, let hostPID,
               NSRunningApplication(processIdentifier: hostPID)?.bundleIdentifier == Self.hostBundleID { return nil }
            if host == nil { originalVisibility = showMenuBarExtra }
            host = request.clientID
            if hostPID != peerPID {
                hostExit?.cancel()
                hostPID = peerPID
                let source = DispatchSource.makeProcessSource(identifier: peerPID, eventMask: .exit, queue: .main)
                source.setEventHandler { [weak self] in
                    MainActor.assumeIsolated {
                        if self?.hostPID == peerPID { self?.detach() }
                    }
                }
                hostExit = source
                source.resume()
            }
            if mixerPresentation == nil { setIconVisible(false) }
            expiry?.cancel()
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                self?.detach()
            }
            subscribed = request.action == "subscribe"
            return subscribed ? snapshot(for: request.clientID) : nil
        }

        guard request.clientID == host, request.clientPID == hostPID else { return nil }
        switch request.action {
        case "unsubscribe":
            subscribed = false
        case "detach":
            detach()
        case "openMixer":
            StrataMixerDestination.shared.clear()
            if !popupVisibility.isVisible { togglePopup() }
        case "openSettings":
            StrataMixerDestination.shared.clear()
            NotificationCenter.default.post(name: Self.openSettingsNotification, object: nil)
        case "openEditor":
            guard subscribed else { return nil }
            StrataMixerDestination.shared.request(.editor)
            if !popupVisibility.isVisible { togglePopup() }
        case "openAppEQ":
            guard subscribed, engine.permission.status == .authorized, let id = request.id,
                  let row = engine.displayableApps.first(where: { $0.id == id }) else { return nil }
            if case .active(let app) = row, engine.getDeviceUID(for: app) == nil { return nil }
            StrataMixerDestination.shared.request(.equalizer(id))
            if !popupVisibility.isVisible { togglePopup() }
        default:
            guard subscribed else { return nil }
            apply(request)
            return snapshot(for: request.clientID)
        }
        return nil
    }

    private func detach() {
        guard host != nil else { return }
        StrataMixerDestination.shared.clear()
        expiry?.cancel()
        expiry = nil
        host = nil
        hostPID = nil
        hostExit?.cancel()
        hostExit = nil
        subscribed = false
        mixerPresentation?.cancel()
        mixerPresentation = nil
        setIconVisible(originalVisibility)
    }

    // FluidMenuBarExtra installs its scene observer after creating the status
    // item. A cold-launch heartbeat can precede that observer, so reconcile the
    // real button as well as the binding even when the model already matches.
    private func setIconVisible(_ visible: Bool) {
        if statusItem == nil { statusItem = popupController.findStatusItem() }
        if showMenuBarExtra != visible { showMenuBarExtra = visible }
        if let statusItem, statusItem.isVisible != visible { statusItem.isVisible = visible }
    }

    // The existing FluidMenuBarExtra popup positions itself relative to its own
    // button. Restore that anchor for advanced controls and global hotkeys,
    // then release it when the full mixer closes.
    func toggle() {
        StrataMixerDestination.shared.clear()
        togglePopup()
    }

    private func togglePopup() {
        guard host != nil, !popupVisibility.isVisible else {
            popupController.toggle()
            return
        }
        guard mixerPresentation == nil else { return }
        setIconVisible(true)
        mixerPresentation = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled {
                    self.mixerPresentation = nil
                    StrataMixerDestination.shared.clear()
                    if self.host != nil { self.setIconVisible(false) }
                }
            }
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                if let item = self.popupController.findStatusItem(), item.isVisible, item.button?.window != nil {
                    self.popupController.toggle()
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
            while !Task.isCancelled && self.popupVisibility.isVisible {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private struct Device: Encodable {
        let id: String
        let name: String
        let volume: Double
        let muted: Bool
        let isDefault: Bool
        let canSetVolume: Bool
        let canMute: Bool
    }

    private struct App: Encodable {
        let id: String
        let name: String
        let volume: Double
        let muted: Bool
        let deviceID: String?
        let isMultiDevice: Bool
        let boost: Int
        let selectedDeviceIDs: [String]
        let eqEnabled: Bool
        let pinned: Bool
        let isActive: Bool
    }

    private struct Snapshot: Encodable {
        let clientID: UUID
        let processID: Int32
        let appAudioAuthorized: Bool
        let outputPriorityEnabled: Bool
        let outputs: [Device]
        let inputs: [Device]
        let apps: [App]
    }

    private func appSnapshot(_ row: DisplayableApp, visibleOutputs: Set<String>) -> App? {
        let gain: Float
        let muted: Bool
        let deviceID: String?
        let mode: DeviceSelectionMode
        let boost: BoostLevel
        let eqEnabled: Bool
        let selection: Set<String>
        switch row {
        case .active(let app):
            guard let routedUID = engine.getDeviceUID(for: app) else { return nil }
            gain = engine.getVolume(for: app)
            muted = engine.getMute(for: app)
            deviceID = engine.isFollowingDefault(for: app) ? nil : routedUID
            mode = engine.getDeviceSelectionMode(for: app)
            boost = engine.getBoost(for: app)
            eqEnabled = engine.getEQSettings(for: app).isEnabled
            selection = engine.getSelectedDeviceUIDs(for: app)
        case .pinnedInactive:
            gain = engine.getVolumeForInactive(identifier: row.id)
            muted = engine.getMuteForInactive(identifier: row.id)
            deviceID = engine.isFollowingDefaultForInactive(identifier: row.id) ? nil : engine.getDeviceRoutingForInactive(identifier: row.id)
            mode = engine.getDeviceSelectionModeForInactive(identifier: row.id)
            boost = engine.getBoostForInactive(identifier: row.id)
            eqEnabled = engine.getEQSettingsForInactive(identifier: row.id).isEnabled
            selection = engine.getSelectedDeviceUIDsForInactive(identifier: row.id)
        }
        let volume = VolumeMapping.gainToSlider(gain)
        return App(id: row.id, name: row.displayName, volume: volume,
                   muted: muted || (volume * 100).rounded() == 0, deviceID: deviceID,
                   isMultiDevice: mode == .multi, boost: Int(boost.rawValue),
                   selectedDeviceIDs: selection.intersection(visibleOutputs).sorted(),
                   eqEnabled: eqEnabled, pinned: engine.isPinned(identifier: row.id), isActive: row.isActive)
    }

    private func snapshot(for client: UUID) -> Data? {
        let outputs = engine.menuOutputDevices.map { device in
            let tier = engine.outputVolumeBackend(for: device.id)
            let volume = VolumeMapping.sliderFraction(forSystemGain: monitor.volumes[device.id] ?? 1, tier: tier)
            return Device(id: device.uid, name: device.name,
                          volume: volume, muted: monitor.muteStates[device.id] == true || (volume * 100).rounded() == 0, isDefault: device.id == monitor.defaultDeviceID,
                          canSetVolume: true,
                          canMute: tier != .hardware || supports(device.id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput))
        }
        let inputs = engine.menuInputDevices.map { device in
            let volume = Double(monitor.inputVolumes[device.id] ?? 1)
            return Device(id: device.uid, name: device.name, volume: volume,
                   muted: monitor.inputMuteStates[device.id] == true || (volume * 100).rounded() == 0, isDefault: device.id == monitor.defaultInputDeviceID,
                   canSetVolume: supports(device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                   canMute: supports(device.id, kAudioDevicePropertyMute))
        }
        let visibleOutputs = Set(outputs.map(\.id))
        let apps = engine.displayableApps.compactMap { appSnapshot($0, visibleOutputs: visibleOutputs) }
        let snapshot = Snapshot(clientID: client, processID: ProcessInfo.processInfo.processIdentifier,
                                appAudioAuthorized: engine.permission.status == .authorized,
                                outputPriorityEnabled: engine.settingsManager.appSettings.outputDevicePriorityEnabled,
                                outputs: outputs, inputs: inputs, apps: apps)
        return try? JSONEncoder().encode(snapshot)
    }

    private func supports(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeInput) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var writable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &address) && AudioObjectIsPropertySettable(id, &address, &writable) == noErr && writable.boolValue
    }

    private func apply(_ request: Request) {
        if request.action == "setOutputPriority" {
            if let enabled = request.enabled { engine.setOutputDevicePriorityEnabled(enabled) }
            return
        }
        guard let id = request.id else { return }
        if request.action == "setVolume" {
            guard let value = request.value, (0...1).contains(value) else { return }
        }
        switch request.kind {
        case "output":
            guard let device = engine.menuOutputDevices.first(where: { $0.uid == id }) else { return }
            let tier = engine.outputVolumeBackend(for: device.id)
            switch request.action {
            case "setVolume":
                guard let fraction = request.value else { return }
                if fraction > 0 && monitor.muteStates[device.id] == true { monitor.setMute(for: device.id, to: false) }
                monitor.setVolume(for: device.id, to: VolumeMapping.systemGain(forSliderFraction: fraction, tier: tier))
            case "setMute":
                guard let muted = request.muted else { return }
                monitor.setMute(for: device.id, to: muted)
                if !muted {
                    let volume = VolumeMapping.sliderFraction(forSystemGain: monitor.volumes[device.id] ?? 1, tier: tier)
                    if (volume * 100).rounded() == 0 {
                        monitor.setVolume(for: device.id, to: VolumeMapping.systemGain(forSliderFraction: 0.5, tier: tier))
                    }
                }
            case "setDefault":
                if device.id != monitor.defaultDeviceID { engine.setDefaultOutputDevice(device.id) }
            default: break
            }
        case "input":
            guard let device = engine.menuInputDevices.first(where: { $0.uid == id }) else { return }
            switch request.action {
            case "setVolume":
                guard let fraction = request.value, supports(device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) else { return }
                monitor.setInputVolume(for: device.id, to: Float(fraction))
                if fraction > 0 && monitor.inputMuteStates[device.id] == true { monitor.setInputMute(for: device.id, to: false) }
            case "setMute":
                guard let muted = request.muted, supports(device.id, kAudioDevicePropertyMute) else { return }
                monitor.setInputMute(for: device.id, to: muted)
                if !muted, ((monitor.inputVolumes[device.id] ?? 1) * 100).rounded() == 0,
                   supports(device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) {
                    monitor.setInputVolume(for: device.id, to: 0.5)
                }
            case "setDefault":
                if device.id != monitor.defaultInputDeviceID { engine.setLockedInputDevice(device) }
            default: break
            }
        case "app":
            guard let row = engine.displayableApps.first(where: { $0.id == id }) else { return }
            if case .active(let app) = row, engine.getDeviceUID(for: app) == nil { return }
            apply(request, to: row)
        default: break
        }
    }

    private func apply(_ request: Request, to row: DisplayableApp) {
        let id = row.id
        switch request.action {
        case "setVolume":
            guard let fraction = request.value else { return }
            let gain = VolumeMapping.sliderToGain(fraction)
            switch row {
            case .active(let app):
                engine.setVolume(for: app, to: gain)
                if fraction > 0 && engine.getMute(for: app) { engine.setMute(for: app, to: false) }
            case .pinnedInactive:
                engine.setVolumeForInactive(identifier: id, to: gain)
                if fraction > 0 && engine.getMuteForInactive(identifier: id) { engine.setMuteForInactive(identifier: id, to: false) }
            }
        case "setMute":
            guard let muted = request.muted else { return }
            switch row {
            case .active(let app):
                if !muted && (VolumeMapping.gainToSlider(engine.getVolume(for: app)) * 100).rounded() == 0 {
                    engine.setVolume(for: app, to: 1)
                }
                engine.setMute(for: app, to: muted)
            case .pinnedInactive:
                if !muted && (VolumeMapping.gainToSlider(engine.getVolumeForInactive(identifier: id)) * 100).rounded() == 0 {
                    engine.setVolumeForInactive(identifier: id, to: 1)
                }
                engine.setMuteForInactive(identifier: id, to: muted)
            }
        case "setPinned":
            guard let enabled = request.enabled else { return }
            if !enabled {
                engine.unpinApp(id)
            } else if case .active(let app) = row, !engine.isPinned(app) {
                engine.pinApp(app)
            }
        case "setEQEnabled":
            guard let enabled = request.enabled else { return }
            switch row {
            case .active(let app):
                var settings = engine.getEQSettings(for: app)
                settings.isEnabled = enabled
                engine.setEQSettings(settings, for: app)
            case .pinnedInactive:
                var settings = engine.getEQSettingsForInactive(identifier: id)
                settings.isEnabled = enabled
                engine.setEQSettingsForInactive(settings, identifier: id)
            }
        case "setBoost":
            guard let value = request.boost, (1...4).contains(value), let boost = BoostLevel(rawValue: Float(value)) else { return }
            switch row {
            case .active(let app): engine.setBoost(for: app, to: boost)
            case .pinnedInactive: engine.setBoostForInactive(identifier: id, to: boost)
            }
        case "setRoute":
            if let uid = request.deviceID, !engine.menuOutputDevices.contains(where: { $0.uid == uid }) { return }
            switch row {
            case .active(let app):
                if engine.getDeviceSelectionMode(for: app) == .multi { engine.setDeviceSelectionMode(for: app, to: .single) }
                engine.setDevice(for: app, deviceUID: request.deviceID)
            case .pinnedInactive:
                engine.setDeviceSelectionModeForInactive(identifier: id, to: .single)
                engine.setDeviceRoutingForInactive(identifier: id, deviceUID: request.deviceID)
            }
        case "setRoutes":
            guard let uids = request.selectedDeviceIDs else { return }
            setRoutes(uids, for: row)
        default: break
        }
    }

    private func setRoutes(_ uids: [String], for row: DisplayableApp) {
        let selected = Set(uids)
        let visible = Set(engine.menuOutputDevices.map(\.uid))
        guard selected.count == uids.count, selected.isSubset(of: visible) else { return }

        // A menu edit only replaces choices the user can see. The engine has
        // separate live and saved selections so a disconnected output can
        // rejoin later without being submitted to a live CoreAudio tap.
        let saved = engine.getSelectedDeviceUIDsForInactive(identifier: row.id)
        var newSaved = saved.subtracting(visible).union(selected)
        switch row {
        case .active(let app):
            let connected = Set(engine.outputDevices.map(\.uid))
            let live = engine.getSelectedDeviceUIDs(for: app)
            let hiddenLive = live.intersection(connected).subtracting(visible)
            let newLive = selected.union(hiddenLive)
            newSaved.formUnion(newLive)
            engine.setSelectedDeviceUIDs(for: app, to: newLive)
            engine.setDeviceSelectionMode(for: app, to: .multi)
            // setSelectedDeviceUIDs persists the live list. Restore reconnect
            // preferences when it differed from the edited visible selection.
            if newSaved != newLive { engine.setSelectedDeviceUIDsForInactive(identifier: row.id, to: newSaved) }
        case .pinnedInactive:
            engine.setSelectedDeviceUIDsForInactive(identifier: row.id, to: newSaved)
            engine.setDeviceSelectionModeForInactive(identifier: row.id, to: .multi)
        }
    }
}
