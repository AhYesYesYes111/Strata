import Testing
@testable import FineTune

@Suite("Devices offered by the standalone and Strata menus")
@MainActor
struct MenuDeviceVisibilityTests {
    private let devices = ["headphones", "speakers", "virtual"].enumerated().map { index, uid in
        AudioDevice(id: UInt32(index + 1), uid: uid, name: uid, icon: nil, supportsAutoEQ: false)
    }

    @Test func hidesDevicesWhileKeepingDefaultAndPriorityOrder() {
        let visible = AudioEngine.menuDevices(devices, defaultUID: "speakers") { $0 != "headphones" }
        #expect(visible.map(\.uid) == ["headphones", "speakers"])
    }

    @Test func preservesChoicesDuringDefaultDeviceTransition() {
        let visible = AudioEngine.menuDevices(devices, defaultUID: nil) { _ in true }
        #expect(visible.map(\.uid) == devices.map(\.uid))
        #expect(AudioEngine.menuDevices([], defaultUID: nil) { _ in true }.isEmpty)
    }
}
