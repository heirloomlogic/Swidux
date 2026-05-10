//
//  FeatureFlagsPlugin.swift
//  SwiduxFeatureFlags
//

import Foundation
import Swidux

/// A Swidux plugin for feature flags + A/B variants + remote-tunable values.
///
/// State lives in ``FeatureFlagsState``. Reads happen via typed ``BoolFlag`` /
/// ``VariantFlag`` / ``ValueFlag`` against the store. Bucketing is pure FNV-1a
/// against the configured identity. The wire format is fetched by
/// ``FeatureFlagsService`` (default: ``HTTPFeatureFlagsService``) and cached
/// in `KeyValueStore`.
@MainActor
public final class FeatureFlagsPlugin<RootState, RootAction>: SwiduxPlugin {
    public typealias State = RootState
    public typealias Action = RootAction

    private let stateKeyPath: WritableKeyPath<RootState, FeatureFlagsState>
    private let toRootAction: @Sendable (FeatureFlagsAction) -> RootAction
    private let extractAction: @Sendable (RootAction) -> FeatureFlagsAction?
    private let service: any FeatureFlagsService
    private let userIDKeyPath: KeyPath<RootState, String?>?
    private let refreshPolicy: RefreshPolicy
    private let keyValueStore: any KeyValueStore
    private let onExposure: (@Sendable (String, FlagValue) -> Void)?

    /// Creates the plugin and wires it into the host's root state and action types.
    ///
    /// - Parameter defaultConfig: bundled fallback config consumed at host
    ///   wiring time via ``FeatureFlagsState/hydrated(from:defaultConfig:)``.
    ///   Stored here for symmetry with other plugin inits but not used by the
    ///   plugin itself.
    public init(
        state: WritableKeyPath<RootState, FeatureFlagsState>,
        action toRootAction: @escaping @Sendable (FeatureFlagsAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> FeatureFlagsAction?,
        service: any FeatureFlagsService,
        userIDKeyPath: KeyPath<RootState, String?>? = nil,
        refreshPolicy: RefreshPolicy = .automatic,
        defaultConfig: FeatureFlagsConfig? = nil,
        keyValueStore: any KeyValueStore,
        onExposure: (@Sendable (String, FlagValue) -> Void)? = nil
    ) {
        self.stateKeyPath = state
        self.toRootAction = toRootAction
        self.extractAction = extractAction
        self.service = service
        self.userIDKeyPath = userIDKeyPath
        self.refreshPolicy = refreshPolicy
        self.keyValueStore = keyValueStore
        self.onExposure = onExposure
        _ = defaultConfig
    }

    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        return reduceLocal(state: &state[keyPath: stateKeyPath], action: local)
    }

    private func reduceLocal(
        state: inout FeatureFlagsState,
        action: FeatureFlagsAction
    ) -> Effect<RootAction>? {
        switch action {
        case .refresh:
            if shouldDebounce(state: state) { return nil }
            state.isFetching = true
            let service = self.service
            let lift = self.toRootAction
            return { send in
                do {
                    let config = try await service.fetch()
                    await send(lift(.refreshSucceeded(config, fetchedAt: Date())))
                } catch {
                    await send(lift(.refreshFailed(String(describing: error))))
                }
            }

        case .refreshSucceeded(let config, let fetchedAt):
            state.config = config
            state.lastFetchedAt = fetchedAt
            state.lastFetchError = nil
            state.isFetching = false
            let store = self.keyValueStore
            return { _ in
                await MainActor.run {
                    store.setValue(config, for: .featureFlagsConfig)
                }
            }

        case .refreshFailed(let message):
            state.lastFetchError = message
            state.isFetching = false
            return nil

        case .setLocalOverride, .clearLocalOverride, .clearAllLocalOverrides, .recordExposure:
            // Implemented in the next task.
            return nil
        }
    }

    private func shouldDebounce(state: FeatureFlagsState) -> Bool {
        guard case .automatic(let minInterval) = refreshPolicy,
            let lastFetched = state.lastFetchedAt
        else {
            return false
        }
        return Date().timeIntervalSince(lastFetched) < minInterval
    }
}
