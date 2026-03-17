//
//  UndoMiddleware.swift
//  Swidux
//
//  Stack-based undo/redo for state snapshots.
//

/// Manages undo/redo stacks for state snapshots.
///
/// Opt-in middleware that captures state before each reducer call and allows
/// restoring previous snapshots. Memory-based — undo history does not survive
/// app relaunch.
///
/// ```swift
/// let undo = UndoMiddleware<AppState>()
///
/// // Before reducer:
/// undo.willReduce(state: currentState)
///
/// // Undo:
/// if let restored = undo.undo(current: currentState) { ... }
///
/// // Redo:
/// if let restored = undo.redo(current: currentState) { ... }
/// ```
///
/// **Coalescing:** Pass `coalescing: true` to group rapid consecutive calls
/// (e.g. per-keystroke text edits) into a single undo step.
@MainActor
public final class UndoMiddleware<State: Equatable & Sendable> {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var lastWasCoalescing = false
    private let maxDepth: Int

    /// Creates an undo middleware.
    ///
    /// - Parameter maxDepth: Maximum number of undo steps to retain. Defaults to
    ///   `Int.max` (effectively unlimited).
    public init(maxDepth: Int = .max) {
        self.maxDepth = maxDepth
    }

    /// Whether there is a state to undo to.
    public var canUndo: Bool { !undoStack.isEmpty }

    /// Whether there is a state to redo to.
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Snapshots the current state before a reducer call.
    ///
    /// Call this from `AppStore.send()` before the reducer runs, for actions
    /// that should be undoable. Clears the redo stack.
    ///
    /// - Parameters:
    ///   - state: The current state, before the reducer mutates it.
    ///   - coalescing: When `true`, consecutive coalescing calls share a single
    ///     undo entry. The first coalescing call pushes; subsequent consecutive
    ///     coalescing calls are skipped. A non-coalescing call resets the flag.
    public func willReduce(state: State, coalescing: Bool = false) {
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
