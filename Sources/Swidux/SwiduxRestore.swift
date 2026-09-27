//
//  SwiduxRestore.swift
//  Swidux
//
//  Undo/redo restore support for macro-generated `applyRestore` bodies.
//

/// Restores one stored property of a `@Swidux` struct during undo/redo.
/// Emitted into every generated ``SwiduxObservable/applyRestore(from:to:)``
/// body; not meant to be called directly.
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
/// - Anything else is assigned.
public enum SwiduxRestore {
    /// Restores a plain value by assignment.
    public static func restore<Value>(_ current: inout Value, from snapshot: Value) {
        current = snapshot
    }

    /// Restores an entity store, recording the difference as pending changes.
    public static func restore<Entity>(_ current: inout EntityStore<Entity>, from snapshot: EntityStore<Entity>) {
        current.restore(from: snapshot)
    }

    /// Restores nested state through its own `applyRestore`, or leaves
    /// `current` untouched when the type opts out of undo restoration.
    @MainActor
    public static func restore<State: SwiduxObservable>(_ current: inout State, from snapshot: State) {
        guard State.restoresOnUndo else { return }
        State.applyRestore(from: snapshot, to: &current)
    }
}
