//
//  UndoPlugin.swift
//  Swidux
//
//  Stack-based undo/redo for state snapshots.
//

/// Snapshot-based undo/redo plugin.
///
/// Captures state before the reducer runs for actions matching the
/// `isUndoable` predicate. Supports coalescing rapid consecutive
/// actions (e.g. per-keystroke edits) into a single undo step.
///
/// Memory-based — undo history does not survive app relaunch.
///
/// ```swift
/// let undo = UndoPlugin<AppState, AppAction>(
///     isUndoable: { action in
///         if case .editor = action { return true }
///         return false
///     },
///     coalescing: { action in
///         if case .editor(.textChanged) = action { return true }
///         return false
///     }
/// )
/// plugins.register(undo)
///
/// // Direct calls for user-initiated undo/redo:
/// if let restored = undo.undo(current: state) { ... }
/// if let restored = undo.redo(current: state) { ... }
/// ```
@MainActor
public final class UndoPlugin<State: Equatable & Sendable, Action>: SwiduxPlugin {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var lastWasCoalescing = false
    private let maxDepth: Int

    private let isUndoable: @Sendable (Action) -> Bool
    private let isCoalescing: @Sendable (Action) -> Bool

    /// Creates an undo plugin.
    ///
    /// - Parameters:
    ///   - maxDepth: Maximum number of undo steps to retain. Each step holds a
    ///     full `State` snapshot (copy-on-write keeps them cheap, but they pin
    ///     whatever they reference), so the default is a bounded 100 rather
    ///     than unlimited. Pass `.max` if you truly want unbounded history.
    ///   - isUndoable: Predicate that decides which actions trigger a snapshot.
    ///     Defaults to all actions.
    ///   - coalescing: Predicate that decides which actions coalesce with the
    ///     previous snapshot. Consecutive coalescing actions share one undo entry.
    ///     Defaults to no coalescing.
    public init(
        maxDepth: Int = 100,
        isUndoable: @escaping @Sendable (Action) -> Bool = { _ in true },
        coalescing: @escaping @Sendable (Action) -> Bool = { _ in false }
    ) {
        self.maxDepth = maxDepth
        self.isUndoable = isUndoable
        self.isCoalescing = coalescing
    }

    /// Whether there is a state to undo to.
    public var canUndo: Bool { !undoStack.isEmpty }

    /// Whether there is a state to redo to.
    public var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - SwiduxPlugin

    /// Snapshots state when `isUndoable(action)` returns `true`.
    public func willReduce(state: State, action: Action) {
        guard isUndoable(action) else { return }
        let coalescing = isCoalescing(action)

        if coalescing && lastWasCoalescing {
            // Skip — keep the original pre-coalesce snapshot
        } else {
            undoStack.append(state)
            if undoStack.count > maxDepth {
                undoStack.removeFirst()
            }
        }
        redoStack.removeAll()
        lastWasCoalescing = coalescing
    }

    // MARK: - Direct Undo/Redo

    /// Restores the previous state.
    ///
    /// Pops the undo stack and pushes the current state onto the redo stack.
    ///
    /// - Parameter current: The current state (will be pushed to redo).
    /// - Returns: The restored state, or `nil` if nothing to undo.
    public func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        lastWasCoalescing = false
        return previous
    }

    /// Re-applies a previously undone state.
    ///
    /// Pops the redo stack and pushes the current state onto the undo stack.
    ///
    /// - Parameter current: The current state (will be pushed to undo).
    /// - Returns: The restored state, or `nil` if nothing to redo.
    public func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        lastWasCoalescing = false
        return next
    }
}
