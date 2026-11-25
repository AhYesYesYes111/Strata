extension AudioEngine {
    var menuOutputDevices: [AudioDevice] {
        Self.menuDevices(prioritySortedOutputDevices, defaultUID: deviceVolumeMonitor.defaultDeviceUID,
                         isHidden: settingsManager.isOutputDeviceHidden)
    }

    var menuInputDevices: [AudioDevice] {
        Self.menuDevices(prioritySortedInputDevices, defaultUID: deviceVolumeMonitor.defaultInputDeviceUID,
                         isHidden: settingsManager.isInputDeviceHidden)
    }

    // Keep the default accessible. During device changes the default can be
    // momentarily unknown; in that case an all-hidden list falls back to all.
    static func menuDevices(_ devices: [AudioDevice], defaultUID: String?, isHidden: (String) -> Bool) -> [AudioDevice] {
        let visible = devices.filter { $0.uid == defaultUID || !isHidden($0.uid) }
        return visible.isEmpty ? devices : visible
    }
}
