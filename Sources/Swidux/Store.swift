//
//  Store.swift
//  Swidux
//
//  Generic store owning the dispatch cycle and observation layer.
//

import Foundation
import os

/// Logs dispatch diagnostics such as deferred re-entrant sends.
private let dispatchLogger = Logger(subsystem: "swidux", category: "dispatch")

/// Logs unhandled errors thrown by effects.
private let effectLogger = Logger(subsystem: "swidux", category: "effects")

/// Generic store that owns the dispatch cycle, plugin lifecycle, and
/// observation layer.
///
/// Views access state through `@dynamicMemberLookup`, which forwards to the
/// observer class tree. SwiftUI observation tracks the actual `@Observable`
/// stored properties on the observer.
///
/// ```swift
/// @Environment(Store<AppState, AppAction>.self) var store
/// store.counters.values  // tracks `counters` on AppStateObserver
/// store.ui.selectedCounterID  // tracks `selectedCounterID` on UIStateObserver
/// store.send(.counter(.add))
/// ```
@Observable
@MainActor
@dynamicMemberLookup
public final class Store<State: SwiduxObservable, Action> {
    // MARK: - Observation Layer

    /// The `@Observable` class tree providing per-property observation.
    @ObservationIgnored
    public let observer: State.Observer

    // MARK: - Dispatch Infrastructure

    @ObservationIgnored
    private let reduce: (inout State, Action) -> Effect<Action>?

    /// Registered plugins driving the dispatch lifecycle.
    @ObservationIgnored
    public let plugins: PluginHost<State, Action>

    // MARK: - Undo

    /// The plugins passed to `init` explicitly, which win over the host's.
    @ObservationIgnored
    private let explicitUndoPlugin: UndoPlugin<State, Action>?

    @ObservationIgnored
    private let explicitPersistencePlugin: PersistencePlugin<State, Action>?

    /// The core plugins found on the host, and how many plugins it held when
    /// they were looked up. The host only ever appends, so a changed count is
    /// exactly "something was registered since".
    @ObservationIgnored
    private var discovered = CorePlugins()

    private struct CorePlugins {
        var pluginCount = 0
        var undo: UndoPlugin<State, Action>?
        var persistence: PersistencePlugin<State, Action>?
    }

    /// The plugin ``undo()`` / ``redo()`` drive.
    private var undoPlugin: UndoPlugin<State, Action>? {
        explicitUndoPlugin ?? discoveredCorePlugins().undo
    }

    /// The plugin ``mutate(_:)`` and undo/redo drain through.
    private var persistencePlugin: PersistencePlugin<State, Action>? {
        explicitPersistencePlugin ?? discoveredCorePlugins().persistence
    }

    /// Looks the core plugins up on the host — lazily, at use, so one
    /// registered after the store was built is found too. `mutate` and
    /// undo/redo are the paths that drain outside the plugin lifecycle, so a
    /// store that couldn't find the persistence plugin recorded their changes
    /// and scheduled nothing: the write reached disk only if a later `send`
    /// happened to drain it first, and an explicit `flush()` — which empties
    /// the writers' buffers but never drains into them — wrote nothing at all.
    /// A store that couldn't find the undo plugin let snapshots pile up while
    /// `undo()` did nothing. Requiring each to be named twice made that the
    /// default outcome.
    private func discoveredCorePlugins() -> CorePlugins {
        let registered = plugins.plugins
        if registered.count != discovered.pluginCount {
            discovered = CorePlugins(
                pluginCount: registered.count,
                undo: registered.lazy.compactMap { $0 as? UndoPlugin<State, Action> }.first,
                persistence: registered.lazy.compactMap { $0 as? PersistencePlugin<State, Action> }.first
            )
        }
        return discovered
    }

    /// Whether there is a state to undo to.
    public private(set) var canUndo = false

    /// Whether there is a state to redo to.
    public private(set) var canRedo = false

    /// Platform undo manager for menu/gesture integration.
    public weak var undoManager: UndoManager?

    /// What the store's steps are registered against, instead of the store.
    ///
    /// `UndoManager` doesn't keep a step's target alive, and invoking a step
    /// whose target was freed traps. A store scoped shorter than its window —
    /// a per-sheet or per-document store, one rebuilt on account switch —
    /// would leave exactly that behind for the next Edit ▸ Undo. Each step
    /// holds this token strongly and the store weakly, so a step that outlives
    /// its store is a no-op, and `deinit` removes the steps by it.
    @ObservationIgnored
    private let undoTarget = UndoTarget()

    /// Guards against re-entrant dispatch; see `send(_:)`.
    @ObservationIgnored
    private var isDispatching = false

    /// Actions dispatched re-entrantly, run as full cycles after the current one.
    @ObservationIgnored
    private var pendingOperations: [@MainActor () -> Void] = []

    // MARK: - Effect Lifecycle

    /// In-flight effect tasks, keyed by an internal UUID. Each entry tracks its
    /// active cancellation scopes (see ``cancellable(id:cancelInFlight:_:)``).
    /// Entries remove themselves on
    /// completion via `effectFinished`; all are cancelled by `cancelEffects()`
    /// and on deinit.
    @ObservationIgnored
    private var effectTasks: [UUID: EffectHandle] = [:]

    /// Whether any effects are still in flight. Test hook.
    var hasInFlightEffects: Bool { !effectTasks.isEmpty }

    // MARK: - Init

    /// Creates a store with the given initial state, reducer, and optional plugins.
    ///
    /// Every snapshot the undo plugin takes is registered with the platform
    /// `UndoManager` as one step, so the plugin's own `isUndoable` predicate
    /// decides what the Edit menu and shake-to-undo offer.
    ///
    /// - Parameters:
    ///   - initialState: The state the observer tree is built from.
    ///   - reducer: The app reducer.
    ///   - plugins: The registered plugins, in execution order.
    ///   - undoPlugin: The plugin ``undo()`` / ``redo()`` drive. **Usually leave
    ///     this nil**: an `UndoPlugin` registered on `plugins` is found
    ///     automatically, even one registered after the store is built. It
    ///     must be registered either way — it snapshots from `willReduce`.
    ///   - persistencePlugin: The plugin ``mutate(_:)`` and undo/redo drain
    ///     through. **Usually leave this nil**: a `PersistencePlugin` registered
    ///     on `plugins` is found automatically, so registering it once is
    ///     enough. Pass it only to drain through a plugin that is deliberately
    ///     *not* registered on the host.
    public init(
        initialState: State,
        reducer: @escaping (inout State, Action) -> Effect<Action>?,
        plugins: PluginHost<State, Action> = PluginHost(),
        undoPlugin: UndoPlugin<State, Action>? = nil,
        persistencePlugin: PersistencePlugin<State, Action>? = nil
    ) {
        self.observer = State.makeObserver(from: initialState)
        self.reduce = reducer
        self.plugins = plugins
        self.explicitUndoPlugin = undoPlugin
        self.explicitPersistencePlugin = persistencePlugin
    }

    /// Creates a store, ignoring a separate platform-undo predicate.
    ///
    /// `isUndoable` once chose which actions registered with the platform
    /// `UndoManager`, apart from which the undo plugin snapshotted. The two
    /// stacks could then disagree: a step the Edit menu offered undid
    /// whichever snapshot was newest, not the one it named. Registration now
    /// follows the plugin's snapshots exactly, so `isUndoable` is ignored —
    /// pass that predicate to `UndoPlugin(isUndoable:)` instead.
    ///
    /// - Parameters:
    ///   - initialState: The state the observer tree is built from.
    ///   - reducer: The app reducer.
    ///   - plugins: The registered plugins, in execution order.
    ///   - undoPlugin: The plugin ``undo()`` / ``redo()`` drive.
    ///   - persistencePlugin: The plugin ``mutate(_:)`` and undo/redo drain through.
    ///   - isUndoable: Ignored.
    @available(
        *, deprecated,
        message: "Platform undo registration follows the UndoPlugin; pass the predicate to UndoPlugin(isUndoable:)."
    )
    public convenience init(
        initialState: State,
        reducer: @escaping (inout State, Action) -> Effect<Action>?,
        plugins: PluginHost<State, Action> = PluginHost(),
        undoPlugin: UndoPlugin<State, Action>? = nil,
        persistencePlugin: PersistencePlugin<State, Action>? = nil,
        isUndoable: @escaping @Sendable (Action) -> Bool
    ) {
        self.init(
            initialState: initialState, reducer: reducer, plugins: plugins, undoPlugin: undoPlugin,
            persistencePlugin: persistencePlugin)
    }

    // MARK: - @dynamicMemberLookup

    /// Forwards property access to the observer class tree.
    public subscript<T>(dynamicMember keyPath: KeyPath<State.Observer, T>) -> T {
        observer[keyPath: keyPath]
    }

    // MARK: - Dispatch

    /// Dispatches an action through the full plugin → reducer → effect cycle.
    ///
    /// Re-entrant calls — a synchronous `send` from inside a reducer or plugin
    /// hook — are deferred and run as full cycles immediately after the current
    /// one, in FIFO order. Running them inline would pack stale state and let
    /// the outer dispatch clobber the inner one's changes. Prefer dispatching
    /// follow-up actions from an `Effect`; deferral is a safety net, and each
    /// occurrence logs a fault.
    public func send(_ action: Action) {
        if isDispatching {
            dispatchLogger.fault("Re-entrant Store.send — deferring until the current mutation completes.")
        }
        perform { self.dispatch(action) }
    }

    /// Every mutation path uses the same FIFO. A nested mutation must pack its
    /// snapshot after the outer one commits, just like a re-entrant action.
    private func perform(_ operation: @escaping @MainActor () -> Void) {
        guard !isDispatching else {
            pendingOperations.append(operation)
            return
        }
        isDispatching = true
        defer { isDispatching = false }
        operation()
        var index = 0
        while index < pendingOperations.count {
            pendingOperations[index]()
            index += 1
        }
        pendingOperations.removeAll()
    }

    /// Runs async work that must not hold state across its suspensions, then
    /// folds the result into a **freshly packed** snapshot in one
    /// suspension-free step.
    ///
    /// This is the supported way to bring the result of an `await` into a live
    /// store. The obvious hand-rolled shape is a lost-write bug:
    ///
    /// ```swift
    /// var snapshot = State(observer: store.observer)   // ← packed BEFORE the await
    /// await load(into: &snapshot)                      // ← dispatches land here…
    /// State.apply(snapshot, to: store.observer)        // ← …and are overwritten here
    /// ```
    ///
    /// `mutate` closes that window by construction. `produce` receives no
    /// state, so it *cannot* hold one across an `await`; `apply` is
    /// synchronous, so no dispatch can interleave between the pack and the
    /// unpack (re-entering the main actor requires a suspension point, and
    /// there is none).
    ///
    /// ```swift
    /// await store.mutate {
    ///     try await api.fetchItems()
    /// } merging: { items, state in
    ///     state.items.merge(from: EntityStore(items)) { _, _ in false }
    /// }
    /// ```
    ///
    /// Entity changes recorded by `apply` are drained and scheduled for
    /// persistence exactly as after a dispatch, and a `send(_:)` issued from
    /// inside `apply` is deferred and runs after the merge commits — see
    /// ``send(_:)``.
    public func mutate<Value>(
        awaiting produce: @MainActor () async throws -> Value,
        merging apply: @escaping @MainActor (Value, inout State) -> Void
    ) async rethrows {
        let value = try await produce()
        mutate { apply(value, &$0) }
    }

    /// Folds a synchronous mutation into a freshly packed snapshot.
    ///
    /// The whole body runs without a suspension point, so no dispatch can land
    /// between the pack and the unpack. Use this directly when the `await`ing
    /// is already done and you just need the result folded in safely;
    /// ``mutate(awaiting:merging:)`` is the same thing with the await attached.
    ///
    /// Entity changes recorded by `apply` are drained and scheduled for
    /// persistence exactly as after a dispatch, and a `send(_:)` issued from
    /// inside `apply` is deferred and runs after the merge commits.
    public func mutate(_ apply: @escaping @MainActor (inout State) -> Void) {
        perform {
            var state = State(observer: self.observer)
            apply(&state)
            self.persistencePlugin?.drainAndScheduleFlush(&state)
            State.apply(state, to: self.observer)
        }
    }

    /// Runs one complete dispatch cycle. Callers must hold `isDispatching`.
    private func dispatch(_ action: Action) {
        var state = State(observer: observer)
        let undoPlugin = undoPlugin
        let snapshotsBefore = undoPlugin?.snapshotCount

        plugins.willReduce(state: state, action: action)
        let effect = reduce(&state, action)
        let pluginEffects = plugins.reduce(state: &state, action: action)
        plugins.afterReduce(state: &state, action: action)

        State.apply(state, to: observer)
        syncUndoState()

        // One platform step per snapshot. A coalesced action shares the step
        // its run opened, and registering it anyway left the Edit menu and
        // shake-to-undo offering steps that undid nothing. Only a snapshot
        // registers, so the two stacks can't disagree about which step is next.
        if let undoPlugin, undoPlugin.snapshotCount != snapshotsBefore {
            registerPlatformStep { $0.undo() }
        }

        let send: Send<Action> = { [weak self] action in
            self?.send(action)
        }
        let allEffects = [effect].compactMap { $0 } + pluginEffects
        for eff in allEffects {
            if case .cancel(let key) = eff.cancellation {
                cancelCancellable(id: key)
                continue
            }
            // `send` is synchronous on the MainActor, so the task is registered
            // before the completion hop below can possibly run.
            let id = UUID()
            var declared: (token: UUID, scope: ActiveScope)?
            if case .scope(let key, let cancelInFlight) = eff.cancellation {
                if cancelInFlight { cancelScopes(reporting: false) { scope, _ in scope.id == key } }
                declared = (UUID(), eff.activeScope(id: key, send: send))
            }
            // Weak `registrar`, so binding the context does not retain the store.
            let context = EffectContext(
                registrar: self, taskID: id, enclosingScopes: declared.map { [$0.token] } ?? [])
            let task = Task { @concurrent [weak self, declared] in
                await EffectContext.$current.withValue(context) {
                    do {
                        try await eff.run(send, declaredScope: declared)
                    } catch is CancellationError {
                        // Expected on teardown / cancelEffects() / cancel(id:) — not an error.
                    } catch {
                        effectLogger.error("Unhandled effect error: \(String(describing: error))")
                    }
                }
                await self?.effectFinished(id)
            }
            var handle = EffectHandle(task: task)
            if let declared {
                declared.scope.cancellation.attach(task)
                handle.scopes[declared.token] = declared.scope
            }
            effectTasks[id] = handle
        }
    }

    private func effectFinished(_ id: UUID) {
        effectTasks.removeValue(forKey: id)
    }

    /// Cancels all in-flight effects.
    ///
    /// Streaming effects (`for await …`) end at their next suspension point.
    /// Called automatically when the store deinitializes; call it directly to
    /// tear down long-lived effects earlier (for example on scene teardown).
    ///
    /// Each running `cancellable(id:onCancel:_:)` scope's `onCancel` action is
    /// dispatched afterwards, as for ``cancel(id:)``.
    public func cancelEffects() {
        let reports = cancelScopes(reporting: true) { _, _ in true }
        for handle in effectTasks.values { handle.task.cancel() }
        effectTasks.removeAll()
        dispatchReports(reports)
    }

    /// Cancels every in-flight effect tagged with `id` via
    /// ``cancellable(id:cancelInFlight:_:)``.
    ///
    /// Safe to call from view or scene lifecycle code (e.g. `.onDisappear`);
    /// ids with nothing running are ignored. To cancel from *inside* a reducer,
    /// return the ``cancel(id:)`` effect instead.
    ///
    /// A cancelled keyed effect's own sends are dropped, including one from a
    /// `catch` block, so it can't clear an in-flight flag itself. Give it an
    /// `onCancel:` action, which this dispatches before returning.
    public func cancel(id: some Hashable & Sendable) {
        cancelCancellable(id: AnyHashableSendable(id))
    }

    deinit {
        for handle in effectTasks.values { handle.task.cancel() }
        // Take the store's steps out of the Edit menu. `UndoManager` belongs
        // to the main thread, where a UI-owned store is released; released
        // anywhere else, the steps stay behind as no-ops instead.
        if Thread.isMainThread {
            let target = undoTarget
            MainActor.assumeIsolated {
                undoManager?.removeAllActions(withTarget: target)
            }
        }
    }

    // MARK: - Undo / Redo

    /// Restores the previous state from the undo stack.
    ///
    /// With an ``undoManager`` attached, a direct call — an in-app Undo
    /// button, or a menu command that calls this — is routed through the
    /// platform manager, so the Edit menu, shake-to-undo, and the button all
    /// walk one history.
    public func undo() {
        if let undoManager, routesThroughUndoManager(undoManager, canStep: canUndo && undoManager.canUndo) {
            return undoManager.undo()
        }
        perform {
            guard let undoPlugin = self.undoPlugin else { return }
            let current = State(observer: self.observer)
            guard let restored = undoPlugin.undo(current: current) else { return }
            self.applySnapshot(restored)
            // Only an undo the manager is running files the inverse on its redo
            // stack. Registered from anywhere else it becomes a new *undo*, and
            // the next system Undo would redo what the user just undid.
            if self.undoManager?.isUndoing == true {
                self.registerPlatformStep { $0.redo() }
            }
        }
    }

    /// Re-applies a previously undone state from the redo stack.
    ///
    /// Routed through an attached ``undoManager`` exactly as ``undo()`` is.
    public func redo() {
        if let undoManager, routesThroughUndoManager(undoManager, canStep: canRedo && undoManager.canRedo) {
            return undoManager.redo()
        }
        perform {
            guard let undoPlugin = self.undoPlugin else { return }
            let current = State(observer: self.observer)
            guard let restored = undoPlugin.redo(current: current) else { return }
            self.applySnapshot(restored)
            if self.undoManager?.isRedoing == true {
                self.registerPlatformStep { $0.undo() }
            }
        }
    }

    /// Whether a direct ``undo()`` / ``redo()`` should drive the platform
    /// manager instead of the plugin: the manager then calls back into the
    /// store with `isUndoing` / `isRedoing` set, which is the only way the
    /// inverse lands on the right stack.
    ///
    /// Falls back to stepping the plugin alone, registering nothing, when the
    /// store or the manager has no step to take (the manager was attached
    /// after the edits, say), when
    /// the call is the manager's own callback or arrives mid-dispatch, and when
    /// a group other than the current event's is open — `UndoManager` raises
    /// if asked to undo inside one.
    /// Registers `step` on the platform manager against ``undoTarget``, which
    /// the handler keeps alive, calling into the store only while it lives.
    private func registerPlatformStep(_ step: @escaping @MainActor (Store) -> Void) {
        let target = undoTarget
        undoManager?.registerUndo(withTarget: target) { [weak self] _ in
            withExtendedLifetime(target) {
                if let self { step(self) }
            }
        }
    }

    private func routesThroughUndoManager(_ undoManager: UndoManager, canStep: Bool) -> Bool {
        guard canStep, !isDispatching, !undoManager.isUndoing, !undoManager.isRedoing else { return false }
        return undoManager.groupingLevel == 0 || (undoManager.groupsByEvent && undoManager.groupingLevel == 1)
    }

    private func applySnapshot(_ restored: State) {
        var current = State(observer: observer)
        State.applyRestore(from: restored, to: &current)
        persistencePlugin?.drainAndScheduleFlush(&current)
        State.apply(current, to: observer)
        syncUndoState()
    }

    private func syncUndoState() {
        canUndo = undoPlugin?.canUndo ?? false
        canRedo = undoPlugin?.canRedo ?? false
    }

    // MARK: - Shutdown

    /// Immediately flushes all pending plugin work.
    public func flush() async {
        await plugins.flush()
    }
}

extension Store: @MainActor SwiduxDispatcher {}

/// The target the store's platform undo steps are registered against.
private final class UndoTarget: Sendable {}

// MARK: - Effect Cancellation Registry

/// Only active scopes are retained. UUID tokens distinguish nested same-key scopes.
private struct EffectHandle {
    let task: Task<Void, Never>
    var scopes: [UUID: ActiveScope] = [:]
}

extension Store: EffectCancellationRegistrar {
    func register(_ scope: ActiveScope, token: UUID, in taskID: UUID, cancelInFlight: Bool, sparing: Set<UUID>) {
        guard let handle = effectTasks[taskID], !handle.task.isCancelled else { return }
        if cancelInFlight {
            // Concurrent same-id scopes in this effect are replaced like any
            // other; only the scopes enclosing the new one are spared.
            cancelScopes(reporting: false) { $0.id == scope.id && !sparing.contains($1) }
        }
        effectTasks[taskID]?.scopes[token] = scope
    }

    func unregister(_ taskID: UUID, scope: UUID) {
        effectTasks[taskID]?.scopes.removeValue(forKey: scope)
    }

    func cancelCancellable(id: AnyHashableSendable) {
        dispatchReports(cancelScopes(reporting: true) { scope, _ in scope.id == id })
    }

    /// Cancels every registered scope matching `predicate`, and every scope
    /// nested in one, and returns the `onCancel` reports of those it newly
    /// cancelled when `reporting` — outermost first.
    ///
    /// Nested scopes are cancelled here explicitly, not left to their host
    /// task's cancellation reaching them: that way each reports its own
    /// `onCancel`, whether or not an enclosing scope has one.
    ///
    /// A `cancelInFlight` replacement passes `false`: the action that started
    /// the replacement is already handling the state the report would reset.
    @discardableResult
    private func cancelScopes(
        reporting: Bool,
        where predicate: (ActiveScope, UUID) -> Bool
    ) -> [@MainActor @Sendable () -> Void] {
        var reports: [@MainActor @Sendable () -> Void] = []
        for handle in effectTasks.values {
            let matched = Set(handle.scopes.filter { predicate($0.value, $0.key) }.keys)
            guard !matched.isEmpty else { continue }
            let cancelled = handle.scopes
                .filter { matched.contains($0.key) || !$0.value.enclosingScopes.isDisjoint(with: matched) }
                .map(\.value)
                .sorted { $0.enclosingScopes.count < $1.enclosingScopes.count }
            for scope in cancelled {
                if scope.cancellation.cancel(), reporting, let report = scope.onCancel {
                    reports.append(report)
                }
            }
        }
        return reports
    }

    /// Dispatches `onCancel` reports once every cancellation is in place, so an
    /// action a report triggers can't have its own effects swept up by it.
    private func dispatchReports(_ reports: [@MainActor @Sendable () -> Void]) {
        guard !reports.isEmpty else { return }
        perform {
            // A nested scope reports through its enclosing scopes' guards,
            // which were just flagged along with it.
            ScopeCancellation.$isDeliveringReport.withValue(true) {
                for report in reports { report() }
            }
        }
    }
}
