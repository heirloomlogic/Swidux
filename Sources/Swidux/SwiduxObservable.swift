//
//  SwiduxObservable.swift
//  Swidux
//
//  Bridges value-type state to @Observable class trees.
//

/// Bridges a value-type state struct to an `@Observable` class tree for
/// per-property SwiftUI observation granularity.
///
/// The struct remains the canonical representation — reducers mutate it via
/// `inout`. The observer class tree is a projection that fires `@Observable`
/// notifications only when individual properties change.
///
/// ## Conformance
///
/// ```swift
/// @Swidux
/// nonisolated struct AppState: Equatable, Sendable {
///     var counters: EntityStore<Counter> = .init()
///     @Slice var ui: UIState = .init()
/// }
/// ```
///
/// `@Swidux` generates this conformance automatically; hand-writing it is supported for advanced cases.
///
/// ## Undo restoration
///
/// Undo and redo hand ``applyRestore(from:to:)`` a whole-state snapshot. A type
/// whose values must never be rolled back — state that mirrors the outside
/// world, like a server verdict, a consent decision or an in-flight request —
/// returns `false` from ``restoresOnUndo``, and a parent's generated
/// `applyRestore` then keeps the current value of any property of that type.
@MainActor
public protocol SwiduxObservable: Equatable, Sendable {
    /// The `@Observable` class (or class tree) that provides observation.
    associatedtype Observer: AnyObject & Sendable

    /// Pack: read current state from the observer class tree into a struct snapshot.
    init(observer: Observer)

    /// Factory: create a fresh observer from an initial state value.
    static func makeObserver(from state: Self) -> Observer

    /// Unpack: diff the snapshot against the observer and assign only changed
    /// properties. Triggers `@Observable` notifications only for properties
    /// that actually changed.
    static func apply(_ snapshot: Self, to observer: Observer)

    /// Restore: mutates `current` using `EntityStore.restore(from:)` for
    /// change-tracked collections. Called during undo/redo before `apply()`.
    static func applyRestore(from snapshot: Self, to current: inout Self)

    /// Whether undo/redo restores a value of this type from its snapshot.
    ///
    /// Consulted by a parent's generated ``applyRestore(from:to:)`` for every
    /// property of this type, whether or not it is marked `@Slice`. `false`
    /// keeps the property's current value through undo and redo alike. Defaults
    /// to `true`. Every plugin-owned state slice Swidux ships returns `false`.
    ///
    /// This decides *what* undo restores. `UndoPlugin`'s `isUndoable`
    /// predicate decides only *when* a snapshot is taken: a snapshot is the
    /// whole state, so restoring it also reverts whatever non-undoable actions
    /// changed since.
    static var restoresOnUndo: Bool { get }
}

extension SwiduxObservable {
    /// Undo restores state by default.
    public static var restoresOnUndo: Bool { true }
}
