//
//  KillswitchPlugin.swift
//  SwiduxKillswitch
//
//  Swidux plugin for remote killswitch enforcement.
//

import Foundation
import Swidux

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A Swidux plugin that evaluates a remote killswitch configuration
/// against the current app version and blocks usage when required.
@MainActor
public struct KillswitchPlugin<RootState, RootAction>: SwiduxPlugin {
    /// Root state type of the host app.
    public typealias State = RootState
    /// Root action type of the host app.
    public typealias Action = RootAction

    private let stateKeyPath: WritableKeyPath<RootState, KillswitchState>
    private let toRootAction: @Sendable (KillswitchAction) -> RootAction
    private let extractAction: @Sendable (RootAction) -> KillswitchAction?
    private let service: KillswitchService
    private let appVersion: @Sendable () -> String
    private let openURL: @Sendable (URL) async -> Void

    /// Creates a killswitch plugin wired into the host app's state and action types.
    ///
    /// - Parameters:
    ///   - state: WritableKeyPath into the root state where the plugin's
    ///     ``KillswitchState`` slice lives.
    ///   - toRootAction: Lifts a ``KillswitchAction`` into the host's root
    ///     action enum (e.g. `AppAction.killswitch`).
    ///   - extractAction: Unwraps a ``KillswitchAction`` from the host's root
    ///     action when present, returning `nil` for unrelated actions.
    ///   - service: Fetches and caches the remote killswitch config.
    ///   - appVersion: Must return a SemVer string (`"1.2.3"`,
    ///     prerelease/build suffixes allowed) — typically
    ///     `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`.
    ///     **Fail-open policy:** if the returned string is unparseable, or the
    ///     config can't be fetched and no cache exists, the verdict is
    ///     `.allowed` — a broken config channel never locks users out.
    ///   - openURL: Opens the blocked verdict's update URL. Defaults to the
    ///     platform opener (`UIApplication` / `NSWorkspace`).
    public init(
        state: WritableKeyPath<RootState, KillswitchState>,
        action toRootAction: @escaping @Sendable (KillswitchAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> KillswitchAction?,
        service: KillswitchService,
        appVersion: @escaping @Sendable () -> String,
        openURL: @escaping @Sendable (URL) async -> Void = { url in
            #if canImport(UIKit)
            await MainActor.run { UIApplication.shared.open(url) }
            #elseif canImport(AppKit)
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            #endif
        }
    ) {
        self.stateKeyPath = state
        self.toRootAction = toRootAction
        self.extractAction = extractAction
        self.service = service
        self.appVersion = appVersion
        self.openURL = openURL
    }

    /// Routes killswitch actions and returns effects for async work.
    public func reduce(
        state: inout RootState,
        action: RootAction
    ) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        let localEffect = reduceLocal(
            state: &state[keyPath: stateKeyPath],
            action: local
        )
        guard let localEffect else { return nil }
        let lift = toRootAction
        return { send in
            try await localEffect { localAction in
                send(lift(localAction))
            }
        }
    }

    private func reduceLocal(
        state: inout KillswitchState,
        action: KillswitchAction
    ) -> Effect<KillswitchAction>? {
        switch action {
        case .fetch:
            let service = self.service
            let appVersion = self.appVersion()
            let lastFetch = state.lastFetch
            return { send in
                // A negative age means the wall clock moved backward past the
                // last fetch; treat the cache as expired rather than letting a
                // clock change pin this install to a stale verdict.
                let cacheAge = lastFetch.map { Date().timeIntervalSince($0) }
                if let cacheAge, cacheAge >= 0, cacheAge < service.cacheLifetime,
                    let cached = service.loadCached()
                {
                    let verdict = KillswitchVerdict.evaluate(
                        cached, against: appVersion
                    )
                    await send(.verdictReceived(verdict, fromNetwork: false))
                    return
                }
                await Self.fetchFromNetwork(
                    service: service, appVersion: appVersion, send: send
                )
            }

        case .forceFetch:
            let service = self.service
            let appVersion = self.appVersion()
            return { send in
                await Self.fetchFromNetwork(
                    service: service, appVersion: appVersion, send: send
                )
            }

        case .verdictReceived(let verdict, let fromNetwork):
            state.verdict = verdict
            state.fetchError = nil
            // Only a live fetch refreshes the freshness window. A cache-served
            // verdict re-stamping `lastFetch` would slide the window forever
            // and starve the network path for the rest of the session.
            if fromNetwork {
                state.lastFetch = Date()
            }

        case .fetchFailed(let message):
            state.fetchError = message

        case .openUpdateURL:
            guard let url = state.verdict.openableUpdateURL else { return nil }
            let openURL = self.openURL
            return { _ in await openURL(url) }
        }
        return nil
    }

    nonisolated private static func fetchFromNetwork(
        service: KillswitchService,
        appVersion: String,
        send: @escaping Send<KillswitchAction>
    ) async {
        do {
            let config = try await service.fetch()
            service.saveCached(config)
            let verdict = KillswitchVerdict.evaluate(
                config, against: appVersion
            )
            await send(.verdictReceived(verdict, fromNetwork: true))
        } catch {
            if let cached = service.loadCached() {
                let verdict = KillswitchVerdict.evaluate(
                    cached, against: appVersion
                )
                await send(.verdictReceived(verdict, fromNetwork: false))
            }
            await send(.fetchFailed(error.localizedDescription))
        }
    }
}
