import AppKit
import Combine
import UniformTypeIdentifiers

enum FineTuneKind: String, Encodable {
    case input, output, app
}

struct FineTuneDevice: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let volume: Double
    let muted: Bool
    let isDefault: Bool
    let canSetVolume: Bool
    let canMute: Bool
}

struct FineTuneAudioApp: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let volume: Double
    let muted: Bool
    let deviceID: String?
    let isMultiDevice: Bool
    var selectedDeviceIDs: [String]?
    var boost: Int?
    var eqEnabled: Bool?
    var pinned: Bool?
    var isActive: Bool?
}

private struct MixerSnapshot: Decodable, Equatable {
    let clientID: String
    let processID: Int32
    let outputs: [FineTuneDevice]
    let inputs: [FineTuneDevice]
    let apps: [FineTuneAudioApp]
    let appAudioAuthorized: Bool
    let outputPriorityEnabled: Bool?
}

private struct MixerRequest: Encodable {
    let action: String
    let clientID: String
    let clientPID: Int32
    let targetPID: Int32
    var kind: FineTuneKind?
    var id: String?
    var value: Double?
    var muted: Bool?
    var deviceID: String?
    var selectedDeviceIDs: [String]?
    var boost: Int?
    var enabled: Bool?
}

@MainActor
final class FineTuneConnection: NSObject, ObservableObject {
    static let shared = FineTuneConnection()
    private static let identifiers = ["io.github.ahyesyesyes111.FineTune.Custom", "com.finetuneapp.FineTune"]
    // Keep socket waits off the main actor. While a request is in flight, a
    // drag only needs its latest value, but a following mute or route is ordered.
    private let transport = DispatchQueue(label: "Strata.FineTuneConnection")
    private var pending: [MixerRequest] = []
    private var transmitting = false
    private let clientID = UUID().uuidString
    private var peer: NSRunningApplication?
    private var peerLacksVisibilityFilter = false
    private var heartbeat: Task<Void, Never>?
    private var socketDirectory: MixerSocketDirectory?
    private var runningAppsObservation: AnyCancellable?
    private var started = false
    private var showing = false
    private var attemptedAutomaticLaunch = false
    private var awaitingStartupPID: pid_t?
    private var lastResponse = TimeInterval.zero
    @Published private var snapshot: MixerSnapshot?
    @Published private var availability = Availability.ready

    private enum Availability: Equatable {
        case ready, opening, waiting, incompatible, missing, failed, launchFailed
    }

    var connected: Bool { snapshot != nil }
    var outputs: [FineTuneDevice] { snapshot?.outputs ?? [] }
    var inputs: [FineTuneDevice] { snapshot?.inputs ?? [] }
    var apps: [FineTuneAudioApp] { snapshot?.apps ?? [] }
    var appAudioAuthorized: Bool { snapshot?.appAudioAuthorized == true }
    var outputPriorityEnabled: Bool? { snapshot?.outputPriorityEnabled }

    var connectionMessage: String {
        guard #available(macOS 15.4, *) else {
            return tr("FineTune 音频控制需要 macOS 15.4 或更新版本。", "FineTune audio controls require macOS 15.4 or later.")
        }
        switch availability {
        case .ready: return tr("连接 FineTune 以控制设备和应用音量。", "Connect FineTune to control device and app volume.")
        case .opening, .waiting: return tr("正在连接 FineTune…", "Connecting to FineTune…")
        case .incompatible: return tr("请先退出正在运行的旧版 FineTune，再连接配套版本。", "Quit the running copy of FineTune, then connect the companion version.")
        case .missing: return tr("请选择支持 Strata 的 FineTune 应用。", "Choose a copy of FineTune that supports Strata.")
        case .failed: return tr("FineTune 未能连接，请重试。", "FineTune could not connect. Try again.")
        case .launchFailed: return tr("FineTune 启动失败。", "FineTune could not start.")
        }
    }

    var launchTitle: String {
        switch availability {
        case .missing: return tr("选择 FineTune…", "Choose FineTune…")
        case .launchFailed: return tr("重试", "Try again")
        default: return tr("连接", "Connect")
        }
    }

    var canLaunch: Bool {
        guard #available(macOS 15.4, *) else { return false }
        return availability != .opening && availability != .waiting && availability != .incompatible
    }

    func start() {
        guard #available(macOS 15.4, *), !started else { return }
        started = true
        runningAppsObservation = NSWorkspace.shared.publisher(for: \.runningApplications, options: [.new])
            .map { apps in
                apps.filter { Self.identifiers.contains($0.bundleIdentifier ?? "") }
                    .map(\.processIdentifier).sorted()
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.beat() }
        beat()
    }

    private func updateHeartbeat(required: Bool) {
        if !required {
            heartbeat?.cancel()
            heartbeat = nil
            return
        }
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                let idle = self?.peer == nil && self?.showing == false
                do { try await Task.sleep(for: .seconds(idle ? 3 : 2), tolerance: .milliseconds(100)) } catch { return }
                self?.beat()
            }
        }
    }

    func stop() {
        started = false
        heartbeat?.cancel()
        heartbeat = nil
        socketDirectory = nil
        pending.removeAll()
        send("detach")
        runningAppsObservation = nil
    }

    func setMenuVisible(_ visible: Bool) {
        guard #available(macOS 15.4, *) else { return }
        showing = visible
        if visible {
            lastResponse = ProcessInfo.processInfo.systemUptime
            beat()
            if !attemptedAutomaticLaunch, peer == nil, availability == .ready, let embedded {
                attemptedAutomaticLaunch = true
                open(embedded)
            }
        } else {
            send("unsubscribe")
            beat()
        }
    }

    private func beat() {
        guard #available(macOS 15.4, *), started else { return }
        if socketDirectory == nil {
            socketDirectory = MixerSocketDirectory(path: FineTuneSocket.directory) { [weak self] replaced in
                if replaced { self?.socketDirectory = nil }
                self?.beat()
            }
        }
        var needsHeartbeat = true
        defer { updateHeartbeat(required: needsHeartbeat) }
        if peer == nil || peer?.isTerminated == true {
            if let dead = peer, awaitingStartupPID == dead.processIdentifier { update(.launchFailed) }
            awaitingStartupPID = nil
            peerLacksVisibilityFilter = false
            if snapshot != nil { snapshot = nil }
            let running = Self.identifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .filter { !$0.isTerminated }
            peer = running.first { $0.bundleURL.map(Self.supportsBridge) == true }
            if peer == nil {
                // The socket can arrive before Launch Services registers the agent.
                // Keep retrying while that live endpoint is unaccounted for.
                if !showing, let socketDirectory {
                    needsHeartbeat = socketDirectory.hasPendingPeer(identifiers: Self.identifiers)
                }
                if !running.isEmpty { update(.incompatible) }
                else if availability != .opening && availability != .failed && availability != .launchFailed {
                    if showing { update(companionURL() == nil ? .missing : .ready) }
                }
                return
            }
            lastResponse = ProcessInfo.processInfo.systemUptime
            update(.waiting)
        }
        guard !peerLacksVisibilityFilter else { return }
        if showing {
            if ProcessInfo.processInfo.systemUptime - lastResponse > 7 {
                if snapshot != nil { snapshot = nil }
                update(.failed)
            }
            send("subscribe")
        } else {
            send("presence")
        }
    }

    private func update(_ newValue: Availability) {
        if availability != newValue { availability = newValue }
    }

    private func receive(_ data: Data) {
        guard started, showing,
              let value = try? JSONDecoder().decode(MixerSnapshot.self, from: data),
              value.clientID == clientID, value.processID == peer?.processIdentifier else { return }
        awaitingStartupPID = nil
        // An update can replace the bundle on disk while its old process is
        // still alive. Its snapshots predate both priority and device filtering.
        guard value.outputPriorityEnabled != nil else {
            peerLacksVisibilityFilter = true
            pending.removeAll()
            send("detach")
            snapshot = nil
            update(.incompatible)
            return
        }
        lastResponse = ProcessInfo.processInfo.systemUptime
        if snapshot != value { snapshot = value }
        attemptedAutomaticLaunch = true
        update(.ready)
    }

    private var embedded: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FineTune.app")
        return Self.supportsBridge(url) ? url : nil
    }

    private static func supportsBridge(_ url: URL) -> Bool {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              identifiers.contains(id) else { return false }
        return bundle.object(forInfoDictionaryKey: "StrataMixerBridgeVersion") as? Int == 2
            && (bundle.object(forInfoDictionaryKey: "StrataMixerControlsRevision") as? Int ?? 0) >= 1
    }

    private func companionURL() -> URL? {
        if let embedded { return embedded }
        return Self.identifiers.lazy.flatMap { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
            .first(where: Self.supportsBridge)
    }

    func launch() {
        guard #available(macOS 15.4, *) else { return }
        beat()
        guard availability != .incompatible && availability != .opening else { return }
        if peer != nil { lastResponse = ProcessInfo.processInfo.systemUptime; update(.waiting); return }
        if let url = companionURL() { open(url); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            guard Self.supportsBridge(url) else { self?.update(.missing); return }
            self?.open(url)
        }
    }

    private func open(_ url: URL) {
        update(.opening)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                guard let self, self.started else { return }
                guard error == nil, let app, !app.isTerminated, app.bundleURL.map(Self.supportsBridge) == true else {
                    self.update(.launchFailed)
                    return
                }
                // The running-app observer may already have received its first snapshot.
                if self.snapshot?.processID == app.processIdentifier { return }
                self.peer = app
                self.awaitingStartupPID = app.processIdentifier
                self.peerLacksVisibilityFilter = false
                self.lastResponse = ProcessInfo.processInfo.systemUptime
                self.update(.waiting)
                self.beat()
            }
        }
    }

    func setVolume(_ value: Double, kind: FineTuneKind, id: String) {
        guard value.isFinite else { return }
        send("setVolume", kind: kind, id: id, value: min(1, max(0, value)))
    }

    func setMute(_ muted: Bool, kind: FineTuneKind, id: String) {
        send("setMute", kind: kind, id: id, muted: muted)
    }

    func setDefault(kind: FineTuneKind, id: String) { send("setDefault", kind: kind, id: id) }
    func setRoute(appID: String, deviceID: String?) { send("setRoute", kind: .app, id: appID, deviceID: deviceID) }
    func setRoutes(appID: String, deviceIDs: [String]) {
        send("setRoutes", kind: .app, id: appID, selectedDeviceIDs: deviceIDs)
    }
    func setBoost(appID: String, multiplier: Int) {
        send("setBoost", kind: .app, id: appID, boost: multiplier)
    }
    func setEQEnabled(appID: String, enabled: Bool) { send("setEQEnabled", kind: .app, id: appID, enabled: enabled) }
    func setPinned(appID: String, pinned: Bool) { send("setPinned", kind: .app, id: appID, enabled: pinned) }
    func setOutputPriority(_ enabled: Bool) { send("setOutputPriority", enabled: enabled) }
    func openAppEQ(appID: String) { send("openAppEQ", kind: .app, id: appID) }
    func openEditor() { send("openEditor") }
    func openMixer() { send("openMixer") }
    func openSettings() { send("openSettings") }

    private func send(_ action: String, kind: FineTuneKind? = nil, id: String? = nil,
                      value: Double? = nil, muted: Bool? = nil, deviceID: String? = nil,
                      selectedDeviceIDs: [String]? = nil, boost: Int? = nil, enabled: Bool? = nil) {
        guard let peer, !peer.isTerminated, !peerLacksVisibilityFilter || action == "detach" else { return }
        let request = MixerRequest(action: action, clientID: clientID, clientPID: ProcessInfo.processInfo.processIdentifier,
                                   targetPID: peer.processIdentifier, kind: kind, id: id, value: value,
                                   muted: muted, deviceID: deviceID, selectedDeviceIDs: selectedDeviceIDs,
                                   boost: boost, enabled: enabled)
        if let last = pending.last, last.targetPID == request.targetPID, last.action == action,
           (action == "setVolume" && last.kind == kind && last.id == id || action == "presence" || action == "subscribe") {
            pending[pending.count - 1] = request
        } else {
            pending.append(request)
        }
        sendNext()
    }

    private func sendNext() {
        guard !transmitting else { return }
        pending.removeAll { $0.targetPID != peer?.processIdentifier }
        guard !pending.isEmpty else { return }
        let request = pending.removeFirst()
        transmitting = true
        transport.async { [weak self] in
            let result = (try? JSONEncoder().encode(request)).flatMap {
                Self.exchange($0, with: request.targetPID, until: FineTuneSocket.deadline())
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.transmitting = false
                // A hidden panel exchanges presence acknowledgements instead of snapshots.
                if request.action == "presence", result != nil, self.awaitingStartupPID == request.targetPID {
                    self.awaitingStartupPID = nil
                }
                if let result, !result.isEmpty { self.receive(result) }
                self.sendNext()
            }
        }
    }

    nonisolated private static func exchange(_ data: Data, with pid: pid_t, until deadline: TimeInterval) -> Data? {
        guard data.count <= FineTuneSocket.requestLimit else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard FineTuneSocket.configure(fd) else { return nil }
        if FineTuneSocket.withAddress(for: pid, { connect(fd, $0, $1) }) < 0 {
            guard errno == EINPROGRESS, FineTuneSocket.ready(fd, for: Int16(POLLOUT), until: deadline) else { return nil }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return nil }
        }
        guard FineTuneSocket.peerPID(fd) == pid,
              FineTuneSocket.write(data, to: fd, until: deadline) else { return nil }
        return FineTuneSocket.read(fd, limit: FineTuneSocket.responseLimit, until: deadline)
    }
}

// A menu-bar agent can launch without a runningApplications KVO update. Its
// bridge socket still appears in this per-user directory. Fall back to the
// discovery heartbeat if the directory cannot be observed.
@MainActor
final class MixerSocketDirectory {
    private let path: String
    private let source: DispatchSourceFileSystemObject

    init?(path: String, changed: @escaping @MainActor (_ replaced: Bool) -> Void) {
        guard !path.isEmpty, mkdir(path, 0o700) == 0 || errno == EEXIST else { return nil }
        let fd = Darwin.open(path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(fd)
            return nil
        }
        self.path = path
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
        // Reconcile once the kernel watch is active, in case a launch raced setup.
        source.setRegistrationHandler { [weak self] in
            if self != nil { changed(false) }
        }
        source.setEventHandler { [weak self] in
            guard let events = self?.source.data else { return }
            changed(!events.intersection([.delete, .rename, .revoke]).isEmpty)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func hasPendingPeer(identifiers: [String]) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return true }
        return entries.contains { name in
            guard name.hasPrefix("v2-"), let pid = pid_t(name.dropFirst(3)), pid > 0,
                  kill(pid, 0) == 0 else { return false }
            var info = stat()
            guard lstat(path + "/" + name, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return false }
            // A stale socket may refer to a PID since reused by a different app.
            if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                return identifiers.contains(id)
            }
            return true
        }
    }

    deinit { source.cancel() }
}
