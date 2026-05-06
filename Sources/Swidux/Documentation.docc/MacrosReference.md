# Macros

Reference for `@SwiduxState` and `@SwiduxNested` — the two macros that generate the observation bridge between value-type state and SwiftUI.

## Why these macros exist

SwiftUI's `@Observable` requires a class. Reducers want a value type so mutation is predictable: a struct passed `inout` is the canonical state, easy to snapshot, easy to diff, easy to undo. The two requirements are in tension. Hand-written code resolves it by maintaining a struct *and* a parallel `@Observable` class tree, then pack-and-unpack between them on every dispatch. The boilerplate is mechanical and error-prone — every new property has to be wired in three places.

`@SwiduxState` writes that boilerplate for you. Applied to a struct, it peer-emits an `@Observable` companion class and an extension making the struct conform to ``SwiduxObservable``. The struct stays the source of truth; the generated class is a projection that fires per-property observation notifications when individual fields change. `@SwiduxNested` is a one-property marker that tells `@SwiduxState` "this property is itself a `@SwiduxState` struct — wire it as a nested observer instead of a leaf."

## `@SwiduxState`

Annotate a state struct to generate its observer class and ``SwiduxObservable`` conformance.

### Signature

```swift
@attached(peer, names: suffixed(Observer))
@attached(extension, conformances: SwiduxObservable, names: arbitrary)
public macro SwiduxState()
```

### What it generates

For a struct named `MyState`, the macro emits:

1. **A peer class `MyStateObserver`** — `@Observable`, `@MainActor`, `final class … : @unchecked Sendable`. One stored property per stored property of the struct.
2. **An extension `MyState: SwiduxObservable`** — providing:
   - `typealias Observer = MyStateObserver`
   - `init(observer:)` — pack: read the observer tree into a struct snapshot.
   - `static func makeObserver(from:) -> MyStateObserver` — factory.
   - `static func apply(_:to:)` — unpack: assign struct fields back onto the observer. `@Observable` only fires notifications for fields whose values actually change.
   - `static func applyRestore(from:to:)` — used during undo/redo. For ``EntityStore`` properties it calls `.restore(from:)` instead of plain assignment, so change tracking stays consistent.

### Requirements on the annotated struct

- **Must be a struct.** Applying `@SwiduxState` to a class or enum emits a diagnostic.
- **Should declare `Equatable` and `Sendable`.** The protocol requires both. The example projects also mark the struct `nonisolated` so it can cross the `@MainActor` boundary inside ``Store``.
- **Stored `var` properties only.** Computed properties, `let` properties, and properties with explicit accessors are ignored.

### Property handling rules

The macro classifies each stored property into one of three kinds and generates code accordingly:

| Property | Kind | Treatment |
|---|---|---|
| `var name: String` | leaf | Mirrored as `var name: String` on the observer; assigned directly in `apply`. |
| `var counters: EntityStore<Counter>` | entityStore | Mirrored as a `var` on the observer; restored via `restore(from:)` during undo. |
| `@SwiduxNested var ui: UIState` | nested | Stored as `let ui: UIStateObserver` on the parent observer; recursive calls to the child's `apply` / `makeObserver` / `applyRestore`. |

Static properties, computed properties, and `let` constants are skipped entirely.

### Example expansion

Given:

```swift
@SwiduxState
nonisolated struct AppState: Equatable, Sendable {
    var counters: EntityStore<Counter> = .init()
    @SwiduxNested var ui: UIState = .init()
}
```

The macro generates:

```swift
@Observable
@MainActor
final class AppStateObserver: @unchecked Sendable {
    var counters: EntityStore<Counter>
    let ui: UIStateObserver

    init(counters: EntityStore<Counter> = .init(), ui: UIStateObserver = UIStateObserver()) {
        self.counters = counters
        self.ui = ui
    }
}

extension AppState: SwiduxObservable {
    typealias Observer = AppStateObserver

    @MainActor
    init(observer: AppStateObserver) {
        self.counters = observer.counters
        self.ui = UIState(observer: observer.ui)
    }

    @MainActor
    static func makeObserver(from state: AppState) -> AppStateObserver {
        AppStateObserver(
            counters: state.counters,
            ui: UIState.makeObserver(from: state.ui)
        )
    }

    @MainActor
    static func apply(_ snapshot: AppState, to observer: AppStateObserver) {
        observer.counters = snapshot.counters
        UIState.apply(snapshot.ui, to: observer.ui)
    }

    @MainActor
    static func applyRestore(from snapshot: AppState, to current: inout AppState) {
        current.counters.restore(from: snapshot.counters)
        UIState.applyRestore(from: snapshot.ui, to: &current.ui)
    }
}
```

Two things worth noticing. First, the nested `ui` property is `let` on the observer — the child observer instance never changes, only its properties do. That's how SwiftUI gets per-field granularity across the boundary. Second, `applyRestore` calls `EntityStore.restore(from:)` on the entity-store property rather than assigning, because plain assignment would discard pending change-tracking metadata.

## `@SwiduxNested`

Marks a property whose type is itself a `@SwiduxState` struct.

### Signature

```swift
@attached(peer)
public macro SwiduxNested()
```

### Purpose

`@SwiduxNested` is a syntactic marker — it generates no code on its own. The parent's `@SwiduxState` macro reads the marker and changes how it generates the parent observer. Without the marker, a nested struct would be treated as a leaf: copied wholesale on every dispatch, firing notifications even when only one inner field changed. With the marker, the parent observer holds the child's observer class instance and recurses into it. SwiftUI observers attached to the inner field only fire when that inner field changes.

### When to use

Use `@SwiduxNested` on any property whose type is also annotated `@SwiduxState`. Typical case: a UI-state slice nested inside `AppState`.

```swift
@SwiduxState
nonisolated struct AppState: Equatable, Sendable {
    var counters: EntityStore<Counter> = .init()
    @SwiduxNested var ui: UIState = .init()
}

@SwiduxState
nonisolated struct UIState: Equatable, Sendable {
    var selectedCounterID: UUID? = nil
}
```

### When NOT to use

- On ``EntityStore`` properties — they have specialized handling already.
- On plain value types (`Int`, `String`, `Date`, `Set<UUID>`, custom `Equatable` value types). These are correctly treated as leaves.
- On any type that isn't itself `@SwiduxState`. The parent will fail to compile because it expects the child to provide `Observer`, `apply`, `makeObserver`, and `applyRestore`.

## Common errors

If you see **"@SwiduxState can only be applied to structs"**, you've put the macro on a class or enum. The generated extension assumes value-type semantics (snapshot, mutate, copy back); classes break that. Convert the type to a struct.

If you see **"cannot find 'ChildStateObserver' in scope"** in the generated code for a parent struct, the property's type isn't annotated `@SwiduxState`, but you marked it `@SwiduxNested`. Either annotate the child type or remove the marker.

If you see **"Type 'X' does not conform to protocol 'Sendable'"** or **"… 'Equatable'"** in the generated extension, the protocol requires both. Add the conformances on the struct.

If your view doesn't update when you change a nested field, you probably forgot `@SwiduxNested`. Without it, the nested struct is treated as an opaque leaf and observers higher up the tree fire on every dispatch instead of only when their own slice changes.

## Restrictions

- **The struct must be `nonisolated`** in practice. The generated extension methods are `@MainActor`, but reducers run with the struct passed `inout` from non-isolated contexts inside ``Store``. Marking the struct `nonisolated` lets it cross that boundary.
- **Properties must be `Sendable`.** The struct itself declares `Sendable`, so the compiler will reject any non-`Sendable` field.
- **Computed properties are not observed.** If you want a derived value to participate in observation, store it (and update it inside the reducer) — or compute it inline in the view.
- **You can opt out.** For exotic shapes (collections of state slices, generic state), hand-write conformance to ``SwiduxObservable`` instead of using the macro. The protocol requires four methods; the macro just removes the boilerplate.

## See Also

- ``SwiduxObservable``
- <doc:BuildingYourFirstApp>
- <doc:ArchitectureGuide>
