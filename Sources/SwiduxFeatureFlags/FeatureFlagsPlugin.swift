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
    /// Host app's root state type.
    public typealias State = RootState
    /// Host app's root action type.
    public typealias Action = RootAction

    private let stateKeyPath: WritableKeyPath<RootState, FeatureFlagsState>
    private let toRootAction: @Sendable (FeatureFlagsAction) -> RootAction
    private let extractAction: @Sendable (RootAction) -> FeatureFlagsAction?
    private let service: any FeatureFlagsService
    private let deviceIDKeyPath: KeyPath<RootState, String>
    private let userIDKeyPath: KeyPath<RootState, String?>?
    private let refreshPolicy: RefreshPolicy
    private let keyValueStore: any KeyValueStore
    private let onExposure: (@Sendable (String, FlagValue) -> Void)?

    /// Creates the plugin and wires it into the host's root state and action types.
    ///
    /// Bundled fallback configs and the bucketing device ID are consumed by
    /// ``FeatureFlagsState/hydrated(from:deviceID:defaultConfig:)`` at host
    /// wiring time, not by the plugin.
    ///
    /// `deviceIDKeyPath` points at the app-owned, stable per-install identity
    /// used for bucketing when no `userIDKeyPath` resolves. Back it with a
    /// Keychain-minted value (see `KeyValueStore.deviceIdentity()`) so it
    /// survives reinstall.
    public init(
        state: WritableKeyPath<RootState, FeatureFlagsState>,
        action toRootAction: @escaping @Sendable (FeatureFlagsAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> FeatureFlagsAction?,
        service: any FeatureFlagsService,
        deviceIDKeyPath: KeyPath<RootState, String>,
        userIDKeyPath: KeyPath<RootState, String?>? = nil,
        refreshPolicy: RefreshPolicy = .automatic,
        keyValueStore: any KeyValueStore,
        onExposure: (@Sendable (String, FlagValue) -> Void)? = nil
    ) {
        self.stateKeyPath = state
        self.toRootAction = toRootAction
        self.extractAction = extractAction
        self.service = service
        self.deviceIDKeyPath = deviceIDKeyPath
        self.userIDKeyPath = userIDKeyPath
        self.refreshPolicy = refreshPolicy
        self.keyValueStore = keyValueStore
        self.onExposure = onExposure
    }

    /// Routes feature-flags actions and returns effects for service fetches,
    /// cache writes, and exposure callbacks.
    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        return reduceLocal(state: &state[keyPath: stateKeyPath], action: local)
    }

    /// Keeps the resolved bucketing identity in sync with the host's keypaths
    /// after every dispatch, so default reads and exposure records bucket by
    /// the signed-in user when one exists (and the device ID otherwise).
    ///
    /// The device ID is seeded at hydration and is constant for the session;
    /// re-resolving it here keeps the slice authoritative if the host's value
    /// ever changes. The user ID changes on sign-in/out, so it must be tracked.
    public func afterReduce(state: inout RootState, action: RootAction) {
        let resolvedDeviceID = state[keyPath: deviceIDKeyPath]
        if state[keyPath: stateKeyPath].resolvedDeviceID != resolvedDeviceID {
            state[keyPath: stateKeyPath].resolvedDeviceID = resolvedDeviceID
        }

        if let userIDKeyPath {
            let resolvedUserID = state[keyPath: userIDKeyPath]
            if state[keyPath: stateKeyPath].resolvedUserID != resolvedUserID {
                state[keyPath: stateKeyPath].resolvedUserID = resolvedUserID
            }
        }
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
                store.setValue(config, for: .featureFlagsConfig)
            }

        case .refreshFailed(let message):
            state.lastFetchError = message
            state.isFetching = false
            return nil

        case .setLocalOverride(let key, let value):
            state.localOverrides[key] = value
            return nil

        case .clearLocalOverride(let key):
            state.localOverrides.removeValue(forKey: key)
            return nil

        case .clearAllLocalOverrides:
            state.localOverrides.removeAll()
            return nil

        case .recordExposure(let key):
            guard !state.exposedKeys.contains(key) else { return nil }
            guard let evaluation = evaluateForExposure(state: state, key: key) else {
                return nil
            }
            state.exposedKeys.insert(key)
            let callback = self.onExposure
            return { _ in
                callback?(key, evaluation)
            }
        }
    }

    /// Resolves the value to record for an exposure. Returns `nil` if the
    /// flag isn't present in the config (defensive — exposure for an unknown
    /// flag is meaningless).
    ///
    /// Bucketing uses the same identity as default reads — the plugin-resolved
    /// user ID when present, else the device ID — so the recorded exposure
    /// matches what the user actually saw. Local overrides take precedence so
    /// QA-toggled flags still record exposures.
    private func evaluateForExposure(state: FeatureFlagsState, key: String) -> FlagValue? {
        if let override = state.localOverrides[key] { return override }
        guard let definition = state.config.flags[key] else { return nil }
        switch definition {
        case .boolean(let rollout):
            let bucket = Bucketing.bucket(id: state.defaultBucketingID, flagKey: key)
            return .bool(bucket < rollout)
        case .variant(let variants):
            // Decoded configs guarantee non-empty variants, but a config can
            // also be constructed programmatically — never index with -1.
            guard !variants.isEmpty else { return nil }
            let bucket = Bucketing.bucket(id: state.defaultBucketingID, flagKey: key)
            let weights = variants.map { $0.weight }
            let index = Bucketing.variantIndex(bucket: bucket, weights: weights)
            return .string(variants[index].value)
        case .value(let value):
            return value
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
