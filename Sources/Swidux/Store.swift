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

    @ObservationIgnored
    private let undoPlugin: UndoPlugin<State, Action>?

    @ObservationIgnored
    private let persistencePlugin: PersistencePlugin<State, Action>?

    @ObservationIgnored
    private let isUndoableAction: (@Sendable (Action) -> Bool)?

    /// Whether there is a state to undo to.
    public private(set) var canUndo = false

    /// Whether there is a state to redo to.
    public private(set) var canRedo = false

    /// Platform undo manager for menu/gesture integration.
    public weak var undoManager: UndoManager?

    /// Guards against re-entrant dispatch; see `send(_:)`.
    @ObservationIgnored
    private var isDispatching = false

    /// Actions dispatched re-entrantly, run as full cycles after the current one.
    @ObservationIgnored
    private var pendingActions: [Action] = []

    // MARK: - Effect Lifecycle

    /// In-flight effect tasks, keyed by an internal UUID. Each entry carries an
    /// optional caller-supplied cancellation id (see
    /// ``cancellable(id:cancelInFlight:_:)``). Entries remove themselves on
    /// completion via `effectFinished`; all are cancelled by `cancelEffects()`
    /// and on deinit.
    @ObservationIgnored
    private var effectTasks: [UUID: EffectHandle] = [:]

    /// Whether any effects are still in flight. Test hook.
    var hasInFlightEffects: Bool { !effectTasks.isEmpty }

    // MARK: - Init

    /// Creates a store with the given initial state, reducer, and optional plugins.
    ///
    /// - Note: `isUndoable` only controls platform `UndoManager` registration
    ///   (menu items, gestures); the `UndoPlugin` snapshots according to its
    ///   *own* `isUndoable` predicate. Pass the same predicate to both —
    ///   if they disagree, actions can be snapshotted without appearing in
    ///   the Edit menu, or vice versa.
    public init(
        initialState: State,
        reducer: @escaping (inout State, Action) -> Effect<Action>?,
        plugins: PluginHost<State, Action> = PluginHost(),
        undoPlugin: UndoPlugin<State, Action>? = nil,
        persistencePlugin: PersistencePlugin<State, Action>? = nil,
        isUndoable: (@Sendable (Action) -> Bool)? = nil
    ) {
        self.observer = State.makeObserver(from: initialState)
        self.reduce = reducer
        self.plugins = plugins
        self.undoPlugin = undoPlugin
        self.persistencePlugin = persistencePlugin
        self.isUndoableAction = isUndoable
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
        guard !isDispatching else {
            dispatchLogger.fault(
                """
                Re-entrant Store.send(\(String(describing: action))) — deferring until the \
                current dispatch completes. Dispatch follow-up actions from an Effect instead.
                """
            )
            pendingActions.append(action)
            return
        }
        isDispatching = true
        defer { isDispatching = false }

        dispatch(action)
        // Index-based drain rather than repeated `removeFirst()` (each O(k),
        // so the loop was O(k²)). Re-read `count` every iteration: an action
        // dispatched mid-drain may append further pending actions, which must
        // still drain FIFO in this same pass.
        var index = 0
        while index < pendingActions.count {
            dispatch(pendingActions[index])
            index += 1
        }
        pendingActions.removeAll()
    }

    /// Runs one complete dispatch cycle. Callers must hold `isDispatching`.
    private func dispatch(_ action: Action) {
        var state = State(observer: observer)

        plugins.willReduce(state: state, action: action)
        let effect = reduce(&state, action)
        let pluginEffects = plugins.reduce(state: &state, action: action)
        plugins.afterReduce(state: &state, action: action)

        State.apply(state, to: observer)
        syncUndoState()

        if let isUndoableAction, isUndoableAction(action) {
            undoManager?.registerUndo(withTarget: self) { $0.undo() }
        }

        let send: Send<Action> = { [weak self] action in
            self?.send(action)
        }
        let allEffects = [effect].compactMap { $0 } + pluginEffects
        for eff in allEffects {
            // `send` is synchronous on the MainActor, so the task is registered
            // before the completion hop below can possibly run.
            let id = UUID()
            // Weak `registrar`, so binding the context does not retain the store.
            let context = EffectContext(registrar: self, taskID: id)
            let task = Task { @concurrent [weak self] in
                await EffectContext.$current.withValue(context) {
                    do {
                        try await eff(send)
                    } catch is CancellationError {
                        // Expected on teardown / cancelEffects() / cancel(id:) — not an error.
                    } catch {
                        effectLogger.error("Unhandled effect error: \(String(describing: error))")
                    }
                }
                await self?.effectFinished(id)
            }
            effectTasks[id] = EffectHandle(task: task)
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
    public func cancelEffects() {
        for handle in effectTasks.values { handle.task.cancel() }
        effectTasks.removeAll()
    }

    /// Cancels every in-flight effect tagged with `id` via
    /// ``cancellable(id:cancelInFlight:_:)``.
    ///
    /// Safe to call from view or scene lifecycle code (e.g. `.onDisappear`);
    /// ids with nothing running are ignored. To cancel from *inside* a reducer,
    /// return the ``cancel(id:)`` effect instead.
    public func cancel(id: some Hashable & Sendable) {
        cancelCancellable(id: AnyHashableSendable(id))
    }

    deinit {
        for handle in effectTasks.values { handle.task.cancel() }
    }

    // MARK: - Undo / Redo

    /// Restores the previous state from the undo stack.
    public func undo() {
        guard let undoPlugin else { return }
        let current = State(observer: observer)
        guard let restored = undoPlugin.undo(current: current) else { return }
        applySnapshot(restored)
        undoManager?.registerUndo(withTarget: self) { $0.redo() }
    }

    /// Re-applies a previously undone state from the redo stack.
    public func redo() {
        guard let undoPlugin else { return }
        let current = State(observer: observer)
        guard let restored = undoPlugin.redo(current: current) else { return }
        applySnapshot(restored)
        undoManager?.registerUndo(withTarget: self) { $0.undo() }
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

// MARK: - Effect Cancellation Registry

/// A running effect task plus its optional caller-supplied cancellation id.
private struct EffectHandle {
    let task: Task<Void, Never>
    var cancelID: AnyHashableSendable?
}

extension Store: EffectCancellationRegistrar {
    func register(_ taskID: UUID, id: AnyHashableSendable, cancelInFlight: Bool) {
        // The new task is still untagged, so cancelling `id` here can't hit it.
        if cancelInFlight { cancelCancellable(id: id) }
        effectTasks[taskID]?.cancelID = id
    }

    func cancelCancellable(id: AnyHashableSendable) {
        // Cancelled tasks remove themselves from `effectTasks` via their own
        // completion hop (`effectFinished`).
        for handle in effectTasks.values where handle.cancelID == id {
            handle.task.cancel()
        }
    }
}
