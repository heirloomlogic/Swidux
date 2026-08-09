# Macros

Reference for `@Swidux` and `@Slice` (the observation bridge between value-type state and SwiftUI), and for `@Persisted` and its property markers (the SwiftData persistence bridge, shipped in `SwiduxPersistence`).

## Why these macros exist

SwiftUI's `@Observable` requires a class. Reducers want a value type so mutation is predictable: a struct passed `inout` is the canonical state, easy to snapshot, easy to diff, easy to undo. The two requirements are in tension. Hand-written code resolves it by maintaining a struct *and* a parallel `@Observable` class tree, then pack-and-unpack between them on every dispatch. The boilerplate is mechanical and error-prone — every new property has to be wired in three places.

`@Swidux` writes that boilerplate for you. Applied to a struct, it peer-emits an `@Observable` companion class and an extension making the struct conform to ``SwiduxObservable``. The struct stays the source of truth; the generated class is a projection that fires per-property observation notifications when individual fields change. `@Slice` is a one-property marker that tells `@Swidux` "this property is itself a `@Swidux` struct — wire it as a nested observer instead of a leaf."

## `@Swidux`

Annotate a state struct to generate its observer class and ``SwiduxObservable`` conformance.

### Signature

```swift
@attached(peer, names: suffixed(Observer))
@attached(extension, conformances: SwiduxObservable, names: arbitrary)
public macro Swidux()
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

- **Must be a struct.** Applying `@Swidux` to a class or enum emits a diagnostic.
- **Should declare `Equatable` and `Sendable`.** The protocol requires both. The example projects also mark the struct `nonisolated` so it can cross the `@MainActor` boundary inside ``Store``.
- **Stored `var` properties only.** Computed properties, `let` properties, and properties with explicit accessors are ignored.

### Property handling rules

The macro classifies each stored property into one of three kinds and generates code accordingly:

| Property | Kind | Treatment |
|---|---|---|
| `var name: String` | leaf | Mirrored as `var name: String` on the observer; assigned directly in `apply`. |
| `var counters: EntityStore<Counter>` | entityStore | Mirrored as a `var` on the observer; restored via `restore(from:)` during undo. |
| `@Slice var ui: UIState` | nested | Stored as `let ui: UIStateObserver` on the parent observer; recursive calls to the child's `apply` / `makeObserver` / `applyRestore`. |

Static properties, computed properties, and `let` constants are skipped entirely.

### Requirements the generated code imposes

The first two rules below are compile errors if you break them. The third is a quirk of
how the observer mirrors access control.

**Give every stored property an inline default if the struct is used as a `@Slice`.**
The parent's generated initializer defaults a nested slice to `ChildObserver()`, so the
child's observer must be constructible with no arguments, which means every one of its
init parameters needs a default. Those defaults are read off the *property declaration*.
A value supplied by a hand-written `init` doesn't count:

```swift
@Swidux
nonisolated struct UIState: Equatable, Sendable {
    var selectedID: UUID? = nil    // ✅ inline
    var zoom: Double               // ❌ "missing argument for parameter 'zoom' in call"
    init(zoom: Double = 1.0) { … } //    …even with this
}
```

Keep the hand-written `init` if you have one — inline defaults are additive, not a
replacement.

**Spell nested types with their qualified name.** The observer is emitted as a *peer* at
file scope, not nested inside your struct, so a bare inner name won't resolve there:

```swift
@Swidux
nonisolated struct PersistenceState: Equatable, Sendable {
    enum HydrationPhase: Sendable, Equatable { case loading, ready }

    var phase: PersistenceState.HydrationPhase = .loading  // ✅
    var other: HydrationPhase = .loading                   // ❌ diagnosed on the property
}
```

The macro reports the bare spelling itself, on the property you wrote, naming the
qualified form to use. Wrappers are seen through — `HydrationPhase?`, `[HydrationPhase]`,
`[String: HydrationPhase]` and `Set<HydrationPhase>` are all caught. `@Persisted` applies
the same rule for the same reason: its `@Model` shadow class is a file-scope peer too.

**`private(set)` and `internal(set)` are not preserved on the observer.** Every stored
property is mirrored as a plain settable `var`, because ``SwiduxObservable/init(observer:)``
packs a snapshot by reading all of them back — a property missing from the observer would
reset to its default on every dispatch. The narrowed setter still guards the reducer
path, and ``Store``'s `@dynamicMemberLookup` exposes read-only key paths, so
`store.someSlice.field = …` doesn't compile. That leaves `store.observer` as the only
way in. A write through it is overwritten by the next dispatch's `apply`.

### Example expansion

Given:

```swift
@Swidux
nonisolated struct AppState: Equatable, Sendable {
    var counters: EntityStore<Counter> = .init()
    @Slice var ui: UIState = .init()
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

## `@Slice`

Marks a property whose type is itself a `@Swidux` struct.

> Note for Redux users: `@Slice` is not the same as Redux Toolkit's `createSlice`. In Redux, a slice owns its own reducer; in Swidux, all reducers operate on the full `AppState` and `@Slice` is purely a structural marker telling the parent's `@Swidux` macro to embed the child as an observer class for per-property observation. Apologies for the term overload — we picked it for memorability and conceptual proximity, not literal equivalence.

### Signature

```swift
@attached(peer)
public macro Slice()
```

### Purpose

`@Slice` is a syntactic marker — it generates no code on its own. The parent's `@Swidux` macro reads the marker and changes how it generates the parent observer. Without the marker, a nested struct would be treated as a leaf: copied wholesale on every dispatch, firing notifications even when only one inner field changed. With the marker, the parent observer holds the child's observer class instance and recurses into it. SwiftUI observers attached to the inner field only fire when that inner field changes.

### When to use

Use `@Slice` on any property whose type is also annotated `@Swidux`. Typical case: a UI-state slice nested inside `AppState`.

```swift
@Swidux
nonisolated struct AppState: Equatable, Sendable {
    var counters: EntityStore<Counter> = .init()
    @Slice var ui: UIState = .init()
}

@Swidux
nonisolated struct UIState: Equatable, Sendable {
    var selectedCounterID: UUID? = nil
}
```

### When NOT to use

- On ``EntityStore`` properties — they have specialized handling already.
- On plain value types (`Int`, `String`, `Date`, `Set<UUID>`, custom `Equatable` value types). These are correctly treated as leaves.
- On any type that isn't itself `@Swidux`. The parent will fail to compile because it expects the child to provide `Observer`, `apply`, `makeObserver`, and `applyRestore`.

## `@Persisted`

Shipped in the `SwiduxPersistence` product (`import SwiduxPersistence`). Annotate a domain entity to generate its SwiftData `@Model` shadow and the value↔model converters, so you never hand-write a `@Model` class, a database actor, or a `StateWriter`. For the end-to-end wiring, see <doc:HowToAddPersistence>.

`@Persisted` operates on a *domain entity* (the value type stored inside an ``EntityStore``); `@Swidux` operates on *state containers*. They are different layers and never apply to the same type. In the rare case a single type needs both, they emit differently-named peers (`{Type}Observer` vs `{Type}Model`) and compose without conflict.

### Signature

```swift
@attached(peer, names: suffixed(Model))
@attached(extension, conformances: PersistableEntity, names: arbitrary)
public macro Persisted()
```

### What it generates

For an entity `Card`, the macro emits:

1. **A peer class `CardModel`** — `@Model final class CardModel: PersistableModel`, with one stored property per mirrored entity property, the relationships and blob columns described below, and the converter trio `init(from:)` / `toDomain()` / `update(from:)` (the latter never reassigns `id`).
2. **An extension `Card: PersistableEntity`** — providing `typealias Model = CardModel`.

One attribute *is* generated, on `id` alone: `@Attribute(.preserveValueOnDeletion)`. SwiftData drops a deleted row's values from persistent history unless they are marked to survive it, and without the identity a delete transaction records that *something* was deleted without recording what — which is all a peer device has to go on when a deletion arrives over CloudKit. Nothing else is preserved, deliberately: a tombstone outlives the row, so any column added to that list is data that deletion does not actually delete. The attribute is transparent to existing stores — it does not change the entity's version hash, so a store written before it was introduced reopens without a migration. It is not retroactive, though: rows deleted *before* it shipped left empty tombstones, and those deletions stay unidentifiable forever. Anything that reads deletions out of history therefore has to treat the first launch after upgrading as a cold start rather than trusting a stored watermark.

No `@Attribute(.unique)` is generated on `id`: CloudKit forbids unique constraints. Identity is therefore a *convention* enforced by `EntityDB`, not a constraint enforced by the store — a fetch by `id` may legitimately return several rows, and mirrored stores do produce that when two devices create the same entity offline. `EntityDB` is written to converge rather than to assume uniqueness: writes update **every** row sharing an `id`, deletions remove **every** row sharing an `id`, and `fetchAll` collapses duplicates to the first row in fetch order. Removing duplicates from disk requires app knowledge of which value wins and is opt-in — see <doc:HowToAddICloudSync>.

The generated model is **CloudKit-safe by construction**, which is what lets the same model back both local and synced containers. SwiftData's CloudKit mirroring requires every non-optional attribute to be optional or carry a default value, and every relationship to be optional — validated at `ModelContainer` creation. `@Persisted` enforces this:

- **Non-optional mirrored attributes get a default** — the default written on the domain property (`var count: Int = 0`) if present, else a canonical default for the known SwiftData primitives (`String → ""`, `Bool → false`, integers/floats `→ 0`, `Date → .distantPast`, `Data → Data()`, `UUID → UUID()`). The default is inert locally; `init(from:)` overwrites it on load.
- **A non-optional, non-primitive mirrored property** with no default and no `@Inline` is a diagnostic (`mirrorRequiresDefault`): add a default, make it optional, or mark it `@Inline`.
- **Relationships are generated optional** (`var tags: [TagModel]? = nil`); a non-optional to-one `@Relation` is a diagnostic (`relationRequiresOptional`).
- **`@Inline` blob columns** default to `Data()`. A non-optional `@Inline` property must carry a domain default (`= …`) — the generated getter falls back to it when the blob is missing or undecodable instead of trapping; omitting it is a diagnostic (`inlineRequiresDefault`). Optional `@Inline` properties fall back to `nil`.

### Requirements on the annotated struct

- **Must be a struct** (a diagnostic fires otherwise).
- **Must satisfy `Identifiable & Equatable & Sendable` with `ID == UUID`** — the ``EntityStore`` contract.

### Property handling and markers

By default every stored property is mirrored directly onto the model — SwiftData persists scalars and `Codable` composites natively. Four marker macros (named to avoid SwiftData's own `@Attribute` / `@Relationship` / `@Transient`) override that:

| Marker | Effect |
|---|---|
| *(none)* | Mirror directly as `var name: T = <default>` — see the CloudKit-safe default rules above. |
| `@Inline` | Store a `Codable` value as one opaque JSON `Data` column (defaulting to `Data()`), exposed through a computed accessor of the original type. The generated class allocates a shared `JSONEncoder`/`JSONDecoder` once per model type. |
| `@ForeignKey` | Intent marker on a `UUID`; functionally a mirrored scalar. |
| `@Relation(deleteRule:inverse:)` | A SwiftData `@Relationship` to another `@Persisted` entity. The property's type references the *domain* type (`[Tag]` / `Tag?` / `Tag`); the model substitutes the `…Model` shadow (always **optional** for CloudKit safety, `= nil`) and the converters map element-by-element. A non-optional to-one `@Relation` is a diagnostic. `deleteRule` is a `SwiduxDeleteRule`; `inverse` is a key path on the generated model (`\TagModel.card`). |
| `@Ignored` | Exclude a derived field. Must be **optional** so `toDomain()` can reconstruct it as `nil` — a diagnostic fires on a non-optional `@Ignored` property. |

### Example expansion

Given:

```swift
@Persisted
nonisolated struct Card: Identifiable, Equatable, Sendable {
    var id: UUID
    var quote: String
    var count: Int
}
```

The macro generates:

```swift
@Model
final class CardModel: PersistableModel {
    typealias Domain = Card

    var id: UUID = UUID()       // CloudKit-safe defaults; overwritten by init(from:)
    var quote: String = ""
    var count: Int = 0

    init(from domain: Card) {
        self.id = domain.id
        self.quote = domain.quote
        self.count = domain.count
    }

    func toDomain() -> Card {
        Card(id: id, quote: quote, count: count)
    }

    func update(from domain: Card) {
        self.quote = domain.quote
        self.count = domain.count
    }
}

extension Card: PersistableEntity {
    typealias Model = CardModel
}
```

(`@Model` itself is a SwiftData macro; the compiler expands it over the generated class. The `SwiduxMacros` plugin emits the class as text and does not import SwiftData.)

## Common errors

If you see **"@Swidux can only be applied to structs"**, you've put the macro on a class or enum. The generated extension assumes value-type semantics (snapshot, mutate, copy back); classes break that. Convert the type to a struct.

If you see **"cannot find 'ChildStateObserver' in scope"** in the generated code for a parent struct, the property's type isn't annotated `@Swidux`, but you marked it `@Slice`. Either annotate the child type or remove the marker.

If you see **"Type 'X' does not conform to protocol 'Sendable'"** or **"… 'Equatable'"** in the generated extension, the protocol requires both. Add the conformances on the struct.

If your view doesn't update when you change a nested field, you probably forgot `@Slice`. Without it, the nested struct is treated as an opaque leaf and observers higher up the tree fire on every dispatch instead of only when their own slice changes.

If you see **"call to main actor-isolated initializer … in a synchronous nonisolated context"** pointing at a `@Swidux` struct, your target is building in **Swift 5 language mode** with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. In that combination the struct's synthesized memberwise init is treated as MainActor-isolated, so the macro's nonisolated reconstruction code can't call it. Adding an explicit `nonisolated init` does **not** fix it — set `SWIFT_VERSION = 6.0` (both Debug and Release). Under Swift 6 language mode, a `nonisolated struct` gets a nonisolated synthesized init automatically. (See the `nonisolated` restriction below.)

## Restrictions

- **The struct must be `nonisolated`** in practice. The generated extension methods are `@MainActor`, but reducers run with the struct passed `inout` from non-isolated contexts inside ``Store``. Marking the struct `nonisolated` lets it cross that boundary.
- **Properties must be `Sendable`.** The struct itself declares `Sendable`, so the compiler will reject any non-`Sendable` field.
- **Computed properties are not observed.** If you want a derived value to participate in observation, store it (and update it inside the reducer) — or compute it inline in the view.
- **You can opt out.** For exotic shapes (collections of state slices, generic state), hand-write conformance to ``SwiduxObservable`` instead of using the macro. The protocol requires four methods; the macro just removes the boilerplate.

## See Also

- ``SwiduxObservable``
- <doc:BuildingYourFirstApp>
- <doc:ArchitectureGuide>
