import Foundation
@_exported import Swidux
import SwiduxFeatureFlags

@Swidux
nonisolated struct AppState: Equatable, Sendable {
    var counters: EntityStore<Counter> = .init()
    @Slice var ui: UIState = .init()
    @Slice var featureFlags: FeatureFlagsState = .init()

    /// Stable, anonymous per-install identity. Minted once at launch from the
    /// Keychain and shared as the feature-flag bucketing identity (and, in an
    /// app with analytics, `AnalyticsIdentity(userID: \.deviceID, …)`).
    var deviceID: String = ""

    init(
        counters: EntityStore<Counter> = EntityStore(),
        ui: UIState = UIState(),
        featureFlags: FeatureFlagsState = FeatureFlagsState(),
        deviceID: String = ""
    ) {
        self.counters = counters
        self.ui = ui
        self.featureFlags = featureFlags
        self.deviceID = deviceID
    }
}

@Swidux
nonisolated struct UIState: Equatable, Sendable {
    var selectedCounterID: UUID? = nil

    /// Delay (in seconds) that the `incrementAsync` effect waits before
    /// dispatching its increment. Tunable from the toolbar slider in
    /// ``ContentView`` to demonstrate ``Store/binding(_:sending:)``.
    var asyncDelay: TimeInterval = 1.0
}
