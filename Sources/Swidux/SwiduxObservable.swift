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
/// struct AppState: SwiduxObservable {
///     var counters = EntityStore<Counter>()
///     var ui = UIState()
/// }
/// ```
///
/// `@Swidux` generates this conformance automatically; hand-writing it is supported for advanced cases.
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
}
