import CoreWLAN

enum LinkQuality {
    /// Associated Wi-Fi signal in dBm. CoreWLAN returns zero for an idle interface or read failure.
    static func signalDBm(interface name: String?) -> Int? {
        guard let name, !name.isEmpty else { return nil }
        let client = CWWiFiClient.shared()
        guard client.interfaceNames()?.contains(name) == true,
              let wifi = client.interface(withName: name), wifi.interfaceName == name else { return nil }
        let signal = wifi.rssiValue()
        return (-127 ..< 0).contains(signal) ? signal : nil
    }
}
