//
//  SwiduxRestore.swift
//  Swidux
//
//  Undo/redo restore support for macro-generated `applyRestore` bodies.
//

/// Computes the restored value of one stored property of a `@Swidux` struct
/// during undo/redo. Emitted into every generated
/// ``SwiduxObservable/applyRestore(from:to:)``; not meant to be called directly.
///
/// ## Why overloads rather than the macro deciding
///
/// How a property restores depends on its *type*, and a macro only sees
/// spelling: `EntityStore<Card>`, `typealias Cards = EntityStore<Card>` and
/// `Swidux.EntityStore<Card>` are one type the syntax can't tell apart. So the
/// generator emits the same call for every property and overload resolution,
/// which runs on the resolved type, picks the behavior:
///
/// - An ``EntityStore`` diffs against the snapshot through
///   ``EntityStore/restore(from:)``, so the restored rows reach persistence as
///   changes rather than arriving with the snapshot's already-drained change set.
/// - A ``SwiduxObservable`` value recurses into its own `applyRestore`, unless
///   its type opts out through ``SwiduxObservable/restoresOnUndo`` — with or
///   without `@Slice`.
/// - An optional or array of a ``SwiduxObservable`` type honors the same
///   opt-out: an opted-out type is kept whole. Otherwise an optional recurses
///   when both sides hold a value, and an array takes the snapshot's elements.
///   No other container is looked into; a dictionary of state, say, is simply
///   assigned.
/// - Anything else is the snapshot's value.
///
/// ## Why values rather than `inout`
///
/// Each overload returns the restored value, and the generated code assigns it
/// inside an initializer. Swift runs a property's `willSet`/`didSet` whenever
/// the property is mutated in place or passed `inout`, but not when an
/// initializer assigns it — and undo must reproduce the snapshot, not replay
/// the side effects of an edit.
public enum SwiduxRestore {
    /// The restored value of a plain property: the snapshot's.
    public static func restored<Value>(_ current: Value, from snapshot: Value) -> Value {
        snapshot
    }

    /// The restored entity store, with the difference recorded as pending changes.
    public static func restored<Entity>(
        _ current: EntityStore<Entity>,
        from snapshot: EntityStore<Entity>
    ) -> EntityStore<Entity> {
        var restored = current
        restored.restore(from: snapshot)
        return restored
    }

    /// The restored nested state, through its own `applyRestore` — or `current`
    /// unchanged when the type opts out of undo restoration.
    @MainActor
    public static func restored<State: SwiduxObservable>(_ current: State, from snapshot: State) -> State {
        guard State.restoresOnUndo else { return current }
        var restored = current
        State.applyRestore(from: snapshot, to: &restored)
        return restored
    }

    /// The restored optional nested state — `current` unchanged when the type
    /// opts out of undo restoration, whichever side is `nil`.
    @MainActor
    public static func restored<State: SwiduxObservable>(_ current: State?, from snapshot: State?) -> State? {
        guard State.restoresOnUndo else { return current }
        guard let current, let snapshot else { return snapshot }
        return restored(current, from: snapshot)
    }

    /// The restored array of nested state — `current` unchanged when the element
    /// type opts out of undo restoration, else the snapshot's elements.
    @MainActor
    public static func restored<State: SwiduxObservable>(_ current: [State], from snapshot: [State]) -> [State] {
        State.restoresOnUndo ? snapshot : current
    }
}
