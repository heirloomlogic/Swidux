//
//  KillswitchPlugin.swift
//  SwiduxKillswitch
//
//  Swidux plugin for remote killswitch enforcement.
//

import Foundation
import Swidux
import Synchronization

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
        return localEffect.map(toRootAction)
    }

    private func reduceLocal(
        state: inout KillswitchState,
        action: KillswitchAction
    ) -> Effect<KillswitchAction>? {
        switch action {
        case .fetch:
            guard !state.isFetching else { return nil }
            // A negative age means the wall clock moved backward past the
            // last fetch; treat the cache as expired rather than letting a
            // clock change pin this install to a stale verdict.
            let cacheAge = state.lastFetch.map { Date().timeIntervalSince($0) }
            guard let cacheAge, cacheAge >= 0, cacheAge < self.service.cacheLifetime else {
                return startNetworkFetch(state: &state)
            }
            let service = self.service
            let appVersion = self.appVersion()
            return Effect { send in
                guard let cached = service.loadCached() else {
                    // Fresh, but nothing on disk (the write failed). Take the
                    // network path through the reducer, so the in-flight
                    // guard sees it.
                    await send(.forceFetch)
                    return
                }
                let verdict = KillswitchVerdict.evaluate(
                    cached, against: appVersion
                )
                await send(.verdictReceived(verdict, fromNetwork: false))
            }

        case .forceFetch:
            guard !state.isFetching else { return nil }
            return startNetworkFetch(state: &state)

        case .verdictReceived(let verdict, let fromNetwork):
            state.verdict = verdict
            state.fetchError = nil
            // Only a live fetch refreshes the freshness window. A cache-served
            // verdict re-stamping `lastFetch` would slide the window forever
            // and starve the network path for the rest of the session. Nor
            // does it end a fetch: the cold-launch preview lands while the
            // request is still in flight.
            if fromNetwork {
                state.lastFetch = Date()
                state.isFetching = false
            }

        case .fetchFailed(let message):
            state.fetchError = message
            state.isFetching = false

        case .openUpdateURL:
            guard let url = state.verdict.openableUpdateURL else { return nil }
            let openURL = self.openURL
            return Effect { _ in await openURL(url) }
        }
        return nil
    }

    /// Marks a network fetch in flight and returns it. The fetch ends in
    /// exactly one of `.verdictReceived(_, fromNetwork: true)` or
    /// `.fetchFailed`, and each clears ``KillswitchState/isFetching``.
    private func startNetworkFetch(
        state: inout KillswitchState
    ) -> Effect<KillswitchAction> {
        state.isFetching = true
        let service = self.service
        let appVersion = self.appVersion()
        // Nothing has decided the verdict yet: a cold launch. The device may
        // already hold a config that blocks this build, so show it while the
        // network answers rather than leave the build usable for the length
        // of the request.
        let previewsCache = state.verdict == .unknown
        return Effect { send in
            let preview = previewsCache ? service.loadCached() : nil
            if let preview {
                let verdict = KillswitchVerdict.evaluate(
                    preview, against: appVersion
                )
                await send(.verdictReceived(verdict, fromNetwork: false))
            }
            await Self.fetchFromNetwork(
                service: service, appVersion: appVersion,
                fallsBackToCache: preview == nil, send: send
            )
        }
    }

    nonisolated private static func fetchFromNetwork(
        service: KillswitchService,
        appVersion: String,
        fallsBackToCache: Bool,
        send: @escaping Send<KillswitchAction>
    ) async {
        do {
            let config = try await boundedFetch(from: service)
            service.saveCached(config)
            let verdict = KillswitchVerdict.evaluate(
                config, against: appVersion
            )
            await send(.verdictReceived(verdict, fromNetwork: true))
        } catch {
            // A previewed cache is already the verdict, and the in-flight
            // guard means nothing has rewritten the file since.
            if fallsBackToCache, let cached = service.loadCached() {
                let verdict = KillswitchVerdict.evaluate(
                    cached, against: appVersion
                )
                await send(.verdictReceived(verdict, fromNetwork: false))
            }
            await send(.fetchFailed(error.localizedDescription))
        }
    }

    /// Runs `service.fetch()` for at most `service.fetchTimeout`.
    ///
    /// Past the bound the fetch is abandoned, not awaited: a custom fetch
    /// that ignores cancellation would otherwise hold ``KillswitchState/isFetching``,
    /// and with it every later fetch, for as long as it runs. It is cancelled
    /// and left to finish on its own; its result is discarded.
    nonisolated private static func boundedFetch(
        from service: KillswitchService
    ) async throws -> KillswitchConfig {
        guard let limit = BoundedResponse.deadline(forTimeout: service.fetchTimeout) else {
            return try await service.fetch()
        }
        let work = Task { try await service.fetch() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outcome = FirstOutcome(continuation)
                let timer = Task {
                    try await Task.sleep(for: limit)
                    outcome.resume(with: .failure(URLError(.timedOut)))
                    work.cancel()
                }
                Task {
                    outcome.resume(with: await work.result)
                    timer.cancel()
                }
            }
        } onCancel: {
            work.cancel()
        }
    }
}

/// Resumes a continuation with whichever result arrives first and drops the
/// rest.
private final class FirstOutcome<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<Value, any Error>) {
        continuation.withLock { $0.take() }?.resume(with: result)
    }
}
