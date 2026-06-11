//
//  Store.swift
//  Swidux
//
//  Generic store owning the dispatch cycle and observation layer.
//

import Foundation

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

    /// Guards against re-entrant dispatch (DEBUG diagnostics only).
    @ObservationIgnored
    private var isDispatching = false

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
    public func send(_ action: Action) {
        // A synchronous send from inside a reducer or plugin hook packs stale
        // state, and the outer dispatch then clobbers the inner one's changes.
        // Dispatch follow-up actions from effects instead — their `send` runs
        // after this cycle completes.
        assert(
            !isDispatching,
            """
            Re-entrant Store.send(\(action)) — dispatch follow-up actions from an Effect, \
            not synchronously from a reducer or plugin hook.
            """
        )
        isDispatching = true
        defer { isDispatching = false }

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
            Task { @concurrent in
                await eff(send)
            }
        }
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
