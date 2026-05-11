import Foundation
@_exported import Swidux
import SwiduxFeatureFlags

@Swidux
nonisolated struct AppState: Equatable, Sendable {
    var counters: EntityStore<Counter> = .init()
    @Slice var ui: UIState = .init()
    @Slice var featureFlags: FeatureFlagsState = .init()

    init(
        counters: EntityStore<Counter> = EntityStore(),
        ui: UIState = UIState(),
        featureFlags: FeatureFlagsState = FeatureFlagsState()
    ) {
        self.counters = counters
        self.ui = ui
        self.featureFlags = featureFlags
    }
}

@Swidux
nonisolated struct UIState: Equatable, Sendable {
    var selectedCounterID: UUID? = nil
}
