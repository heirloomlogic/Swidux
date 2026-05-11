//
//  AnalyticsPlugin.swift
//  SwiduxAnalytics
//

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
/// Plus auto-identify via an optional ``AnalyticsIdentity`` keypath: the
/// plugin watches the userID closure across dispatches and fires
/// `service.identify` / `service.reset` on transitions, with `userProperties`
/// snapshotted at identify time.
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

    /// Number of fire-and-forget service calls in flight.
    private var inflightCount: Int = 0
    /// Continuations parked in ``flush()`` waiting for inflight work to drain to zero.
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []

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
    public init(
        state: WritableKeyPath<RootState, AnalyticsState>,
        action toRootAction: @escaping @Sendable (AnalyticsAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> AnalyticsAction?,
        service: any AnalyticsService,
        mapper: AnalyticsMapper<RootState, RootAction> = .none,
        identity: AnalyticsIdentity<RootState>? = nil
    ) {
        self.stateKeyPath = state
        self.toRootAction = toRootAction
        self.extractAction = extractAction
        self.service = service
        self.mapper = mapper
        self.identity = identity
    }

    // MARK: - Reduce (explicit AnalyticsAction handling)

    /// Routes ``AnalyticsAction`` cases and returns effects for service calls.
    /// Returns `nil` for non-analytics actions (which `afterReduce` then
    /// processes via the mapper and auto-identify).
    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        let localEffect = reduceLocal(state: &state[keyPath: stateKeyPath], action: local)
        guard let localEffect else { return nil }
        let lift = toRootAction
        return { send in
            await localEffect { localAction in
                send(lift(localAction))
            }
        }
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
            return { _ in await service.track(enriched) }

        case .screenView(let name, let extraProperties):
            state.currentScreen = name
            guard !state.isOptedOut else { return nil }
            var properties = extraProperties
            properties["screen_name"] = .string(name)
            let event = AnalyticsEvent("screen_view", properties)
            let service = self.service
            return { _ in await service.track(event) }

        case .identify(let userID, let properties):
            state.lastIdentifiedUserID = userID
            guard !state.isOptedOut else { return nil }
            let service = self.service
            return { _ in
                await service.identify(userID: userID, properties: properties)
            }

        case .alias(let newID, let previousID):
            guard !state.isOptedOut else { return nil }
            let service = self.service
            return { _ in await service.alias(newID: newID, previousID: previousID) }

        case .reset:
            state.lastIdentifiedUserID = nil
            let service = self.service
            return { _ in await service.reset() }

        case .setOptedOut(let optedOut):
            state.isOptedOut = optedOut
            guard optedOut else { return nil }
            state.lastIdentifiedUserID = nil
            let service = self.service
            return { _ in await service.reset() }
        }
    }

    // MARK: - AfterReduce (passive mapper + auto-identify)

    /// Runs auto-identify and the mapper for every non-analytics action.
    /// Skipped entirely when the action is an ``AnalyticsAction`` (those are
    /// handled by `reduce`) or when the user is opted out.
    public func afterReduce(state: inout RootState, action: RootAction) {
        // Explicit analytics actions are handled by `reduce`. Skip mapper and
        // auto-identify so we don't double-track or clobber `lastIdentifiedUserID`
        // that the explicit handler just set.
        if extractAction(action) != nil { return }

        runAutoIdentify(state: &state)
        runMapper(state: state, action: action)
    }

    private func runAutoIdentify(state: inout RootState) {
        guard let identity else { return }
        let analyticsState = state[keyPath: stateKeyPath]
        guard !analyticsState.isOptedOut else { return }

        let currentUserID = identity.userID(state)
        guard currentUserID != analyticsState.lastIdentifiedUserID else { return }

        state[keyPath: stateKeyPath].lastIdentifiedUserID = currentUserID
        let service = self.service

        if let userID = currentUserID {
            let properties = identity.userProperties(state)
            spawn { await service.identify(userID: userID, properties: properties) }
        } else {
            spawn { await service.reset() }
        }
    }

    private func runMapper(state: RootState, action: RootAction) {
        let analyticsState = state[keyPath: stateKeyPath]
        guard !analyticsState.isOptedOut else { return }

        let events = mapper.map(state, action)
        guard !events.isEmpty else { return }

        let currentScreen = analyticsState.currentScreen
        let service = self.service
        let enrichedEvents = events.map { enrich($0, currentScreen: currentScreen) }
        // Single task iterates in order so events from one afterReduce
        // reach the service in mapper-declared sequence (otherwise N
        // racing tasks deliver them non-deterministically).
        spawn {
            for event in enrichedEvents {
                await service.track(event)
            }
        }
    }

    // MARK: - Flush

    /// Awaits any pending service calls spawned by `afterReduce`, then
    /// drains the service's own buffers via `service.flush()`.
    ///
    /// Call during app shutdown (`scenePhase == .background`,
    /// `applicationWillTerminate`) to avoid losing in-flight events.
    public func flush() async {
        if inflightCount > 0 {
            await withCheckedContinuation { continuation in
                flushWaiters.append(continuation)
            }
        }
        await service.flush()
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
    /// Tracking is by counter — Task references are not retained — so
    /// memory stays bounded across long sessions between flushes.
    private func spawn(_ work: @escaping @Sendable () async -> Void) {
        inflightCount += 1
        Task { @concurrent in
            await work()
            await self.markCompleted()
        }
    }

    private func markCompleted() {
        inflightCount -= 1
        guard inflightCount == 0 else { return }
        let waiters = flushWaiters
        flushWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
