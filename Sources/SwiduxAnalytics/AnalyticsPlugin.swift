//
//  AnalyticsPlugin.swift
//  SwiduxAnalytics
//

import Foundation
import Swidux

/// A Swidux plugin that observes the dispatch cycle and forwards events
/// to a provider-agnostic ``AnalyticsService``.
///
/// Two surfaces:
///
/// - **Mapper** (passive): a `(State, Action) -> [AnalyticsEvent]` closure run
///   in `afterReduce` for every non-analytics action. Apps declare it once.
/// - **`AnalyticsAction`** (explicit): screen views, identify/alias/reset,
///   ad-hoc tracks, opt-out toggling.
///
/// Plus auto-identify via an optional ``AnalyticsIdentity``: the plugin
/// re-evaluates `userID` and `userProperties` each non-analytics dispatch
/// and fires `service.identify` whenever either side changes;
/// `service.reset` fires on `userID → nil`.
///
/// ## Consent
///
/// Opting out gates events *plugin-side* — every dispatch path returns early,
/// so nothing reaches the service. That alone does not engage a vendor SDK's
/// own consent switch, which matters when the SDK tracks automatic events or
/// still holds a queue of its own. Supply `onConsentChange` to bridge the two:
///
/// ```swift
/// AnalyticsPlugin(
///     state: \.analytics,
///     action: AppAction.analytics,
///     extractAction: { if case .analytics(let a) = $0 { a } else { nil } },
///     service: mixpanel,
///     onConsentChange: { optedOut in
///         optedOut ? mixpanel.optOutTracking() : mixpanel.optInTracking()
///     }
/// )
/// ```
///
/// ``AnalyticsService`` stays at five members: consent APIs vary too much
/// between vendors to abstract, and only the app knows which it is using.
@MainActor
public final class AnalyticsPlugin<RootState, RootAction>: SwiduxPlugin {
    /// Root state type of the host app.
    public typealias State = RootState
    /// Root action type of the host app.
    public typealias Action = RootAction

    private let stateKeyPath: WritableKeyPath<RootState, AnalyticsState>
    private let toRootAction: @Sendable (AnalyticsAction) -> RootAction
    private let extractAction: @Sendable (RootAction) -> AnalyticsAction?
    private let service: any AnalyticsService
    private let mapper: AnalyticsMapper<RootState, RootAction>
    private let identity: AnalyticsIdentity<RootState>?
    private let onConsentChange: (@Sendable (Bool) async -> Void)?

    /// Number of fire-and-forget service calls in flight.
    private var inflightCount: Int = 0
    /// Continuations parked in ``flush()`` waiting for inflight work to drain
    /// to zero, keyed so a timed-out waiter can be resumed individually.
    private var flushWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Tail of the chain of spawned service-call tasks. Each new spawn
    /// awaits this before running, so service calls reach the service
    /// in submission order even when scheduled on a concurrent executor.
    private var lastSpawnedTask: Task<Void, Never>?
    /// Consent has its own FIFO so a blocked event cannot defer withdrawal.
    private var lastConsentTask: Task<Void, Never>?
    /// Invalidates unsent events when consent is withdrawn, even if the user
    /// opts back in before the queue reaches them.
    private var consentGeneration = UUID()

    /// Creates an analytics plugin wired into the host app.
    ///
    /// - Parameters:
    ///   - state: WritableKeyPath into the root state where the plugin's
    ///     ``AnalyticsState`` slice lives.
    ///   - toRootAction: Lifts an ``AnalyticsAction`` into the host's root
    ///     action enum (e.g. `AppAction.analytics`).
    ///   - extractAction: Unwraps an ``AnalyticsAction`` from the host's root
    ///     action when present, returning `nil` for unrelated actions.
    ///   - service: Backend implementation conforming to ``AnalyticsService``.
    ///   - mapper: Optional declarative `(state, action) -> [AnalyticsEvent]`
    ///     run in `afterReduce` for every non-analytics action.
    ///   - identity: Optional identity source. When present, the plugin
    ///     auto-fires `service.identify` / `service.reset` whenever the
    ///     userID transitions across dispatches.
    ///   - onConsentChange: Optional hook invoked on every `.setOptedOut`
    ///     dispatch with the new opted-out value, so a vendor SDK's own
    ///     consent API engages alongside the plugin's gate. Dispatching the
    ///     value the state already holds calls it again — vendor consent
    ///     APIs are idempotent. See ``AnalyticsAction/setOptedOut(_:)``.
    public init(
        state: WritableKeyPath<RootState, AnalyticsState>,
        action toRootAction: @escaping @Sendable (AnalyticsAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> AnalyticsAction?,
        service: any AnalyticsService,
        mapper: AnalyticsMapper<RootState, RootAction> = .none,
        identity: AnalyticsIdentity<RootState>? = nil,
        onConsentChange: (@Sendable (Bool) async -> Void)? = nil
    ) {
        self.stateKeyPath = state
        self.toRootAction = toRootAction
        self.extractAction = extractAction
        self.service = service
        self.mapper = mapper
        self.identity = identity
        self.onConsentChange = onConsentChange
    }

    // MARK: - Reduce (explicit AnalyticsAction handling)

    /// Routes ``AnalyticsAction`` cases and returns effects for service calls.
    /// Returns `nil` for non-analytics actions (which `afterReduce` then
    /// processes via the mapper and auto-identify).
    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        let localEffect = reduceLocal(state: &state[keyPath: stateKeyPath], action: local)
        guard let localEffect else { return nil }
        return localEffect.map(toRootAction)
    }

    private func reduceLocal(
        state: inout AnalyticsState,
        action: AnalyticsAction
    ) -> Effect<AnalyticsAction>? {
        switch action {
        case .track(let event):
            guard !state.isOptedOut else { return nil }
            let enriched = enrich(event, currentScreen: state.currentScreen)
            let service = self.service
            return enqueue { await service.track(enriched) }

        case .screenView(let name, let extraProperties):
            state.currentScreen = name
            guard !state.isOptedOut else { return nil }
            var properties = extraProperties
            properties["screen_name"] = .string(name)
            let event = AnalyticsEvent("screen_view", properties)
            let service = self.service
            return enqueue { await service.track(event) }

        case .identify(let userID, let properties):
            // Record only when the identify actually reaches the service —
            // recording while opted out would make a later opt-in compare
            // equal and silently skip ever identifying the user.
            guard !state.isOptedOut else { return nil }
            state.recordIdentified(userID: userID, properties: properties)
            let service = self.service
            return enqueue {
                await service.identify(userID: userID, properties: properties)
            }

        case .alias(let newID, let previousID):
            guard !state.isOptedOut else { return nil }
            let service = self.service
            return enqueue { await service.alias(newID: newID, previousID: previousID) }

        case .reset:
            state.clearIdentified()
            let service = self.service
            return enqueue(requiresConsent: false) { await service.reset() }

        case .setOptedOut(let optedOut):
            state.isOptedOut = optedOut
            if optedOut {
                state.clearIdentified()
                consentGeneration = UUID()
            }
            guard optedOut || onConsentChange != nil else { return nil }
            let consent = enqueueConsent(optedOut)
            let service = self.service
            if optedOut {
                return enqueue(requiresConsent: false) { await service.reset() }
            }
            return Effect { _ in await consent.value }
        }
    }

    // MARK: - AfterReduce (passive mapper + auto-identify)

    /// Runs auto-identify and the mapper for every non-analytics action.
    /// Skipped entirely when the action is an ``AnalyticsAction`` (those are
    /// handled by `reduce`) or when the user is opted out.
    public func afterReduce(state: inout RootState, action: RootAction) {
        if extractAction(action) != nil { return }
        runAutoIdentify(state: &state)
        runMapper(state: state, action: action)
    }

    private func runAutoIdentify(state: inout RootState) {
        guard let identity else { return }
        let analyticsState = state[keyPath: stateKeyPath]
        guard !analyticsState.isOptedOut else { return }

        let service = self.service

        guard let userID = identity.userID(state) else {
            guard analyticsState.lastIdentifiedUserID != nil else { return }
            state[keyPath: stateKeyPath].clearIdentified()
            spawn(requiresConsent: false) { await service.reset() }
            return
        }

        let nextProperties = identity.userProperties(state)
        guard
            userID != analyticsState.lastIdentifiedUserID
                || nextProperties != analyticsState.lastIdentifiedProperties
        else { return }

        state[keyPath: stateKeyPath].recordIdentified(userID: userID, properties: nextProperties)
        spawn { await service.identify(userID: userID, properties: nextProperties) }
    }

    private func runMapper(state: RootState, action: RootAction) {
        let analyticsState = state[keyPath: stateKeyPath]
        guard !analyticsState.isOptedOut else { return }

        let events = mapper.map(state, action)
        guard !events.isEmpty else { return }

        let currentScreen = analyticsState.currentScreen
        let service = self.service
        let enrichedEvents = events.map { enrich($0, currentScreen: currentScreen) }
        for event in enrichedEvents {
            spawn { await service.track(event) }
        }
    }

    // MARK: - Flush

    /// Awaits all pending explicit and mapped service calls, then
    /// drains the service's own buffers via `service.flush()`.
    ///
    /// Call during app shutdown (`scenePhase == .background`,
    /// `applicationWillTerminate`) to avoid losing in-flight events.
    ///
    /// This waits without bound — a hung service holds it forever. On
    /// shutdown paths the OS watchdog is the effective limit; prefer
    /// ``flush(timeout:)`` there.
    public func flush() async {
        await drainInflight(timeout: nil)
        await service.flush()
    }

    /// As ``flush()``, but gives up once `timeout` elapses. Work still in
    /// flight when it fires continues in the background — nothing is
    /// cancelled, the wait just stops blocking the caller. Recommended for
    /// `applicationWillTerminate`, where an unbounded wait risks the watchdog.
    ///
    /// - Parameter timeout: Total time budget across the in-flight drain and
    ///   the service's own `flush()`.
    public func flush(timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        await drainInflight(timeout: timeout)
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return }
        let service = self.service
        await Self.race(timeout: remaining) { await service.flush() }
    }

    // MARK: - Helpers

    private func enrich(_ event: AnalyticsEvent, currentScreen: String?) -> AnalyticsEvent {
        guard let currentScreen, event.properties["screen"] == nil else {
            return event
        }
        var enriched = event
        enriched.properties["screen"] = .string(currentScreen)
        return enriched
    }

    /// Spawns a tracked Task on a background executor so afterReduce stays
    /// fast and ``flush()`` can deterministically wait for completion.
    ///
    /// Each new task awaits ``lastSpawnedTask`` before running, chaining
    /// spawns into a single FIFO so concurrent dispatch can't reorder
    /// service calls. Consent hooks have their own FIFO; service work waits
    /// for the consent transition in effect at submission. Completed tails
    /// are released when all tracked work drains.
    private func enqueue(
        requiresConsent: Bool = true,
        _ work: @escaping @Sendable () async -> Void
    ) -> Effect<AnalyticsAction> {
        let task = spawn(requiresConsent: requiresConsent, work)
        return Effect { _ in await task.value }
    }

    @discardableResult
    private func spawn(
        requiresConsent: Bool = true,
        _ work: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        inflightCount += 1
        let previous = lastSpawnedTask
        let generation = consentGeneration
        let consent = lastConsentTask
        let next = Task { @concurrent in
            await previous?.value
            await consent?.value
            let permitted = await self.permits(generation)
            if !requiresConsent || permitted {
                await work()
            }
            await self.markCompleted()
        }
        lastSpawnedTask = next
        return next
    }

    private func enqueueConsent(_ optedOut: Bool) -> Task<Void, Never> {
        inflightCount += 1
        let previous = lastConsentTask
        let hook = onConsentChange
        let next = Task { @concurrent in
            await previous?.value
            await hook?(optedOut)
            await self.markCompleted()
        }
        lastConsentTask = next
        return next
    }

    private func permits(_ generation: UUID) -> Bool { generation == consentGeneration }

    private func markCompleted() {
        inflightCount -= 1
        guard inflightCount == 0 else { return }
        lastSpawnedTask = nil
        lastConsentTask = nil
        let waiters = flushWaiters
        flushWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    /// Parks until in-flight service calls drain to zero, or `timeout`
    /// elapses when one is given. Removal from `flushWaiters` is the claim
    /// ticket — MainActor serialization makes drain and timeout resume a
    /// waiter exactly once.
    private func drainInflight(timeout: Duration?) async {
        guard inflightCount > 0 else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            flushWaiters[id] = continuation
            if let timeout {
                Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    self.timeOutWaiter(id)
                }
            }
        }
    }

    private func timeOutWaiter(_ id: UUID) {
        guard let waiter = flushWaiters.removeValue(forKey: id) else { return }
        waiter.resume()
    }

    /// Awaits `work` or `timeout`, whichever finishes first. The loser keeps
    /// running unobserved — this bounds the wait, it doesn't cancel the work.
    private static func race(
        timeout: Duration,
        _ work: @escaping @Sendable () async -> Void
    ) async {
        let (winner, finishLine) = AsyncStream<Void>.makeStream()
        Task { @concurrent in
            await work()
            finishLine.yield()
        }
        Task { @concurrent in
            try? await Task.sleep(for: timeout)
            finishLine.yield()
        }
        var signals = winner.makeAsyncIterator()
        await signals.next()
    }
}
