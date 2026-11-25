import Observation

/// A request can arrive before the mixer has a key window. Keep it until the
/// visible popup can navigate its existing editor and scroll to the right row.
@MainActor @Observable
final class StrataMixerDestination {
    enum Target: Equatable {
        case editor
        case equalizer(String)
    }

    static let shared = StrataMixerDestination()
    private(set) var pending: Target?

    func request(_ target: Target) { pending = target }
    func clear() { pending = nil }
}
