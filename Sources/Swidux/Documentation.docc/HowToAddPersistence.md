# Add Persistence

Persist your domain entities to SwiftData with the `SwiduxPersistence` plugin and the `@Persisted` macro — no hand-written `@Model` classes, database actors, or `StateWriter` closures.

## Overview

`SwiduxPersistence` turns persistence into a declare-and-register concern. You annotate a domain entity with `@Persisted`; the macro generates its SwiftData `@Model` "shadow" class, the value↔model converters, and the `PersistableEntity` conformance. A generic `EntityDB` actor and a `PersistenceCoordinator` build the container, synthesize one `StateWriter` per registered ``EntityStore``, and reuse the core ``PersistencePlugin`` for debounced, batched writes.

Your reducers mutate plain value-type entities inside an ``EntityStore``; the plugin observes the changelog and writes through to SwiftData after a debounce. Reads happen once, at launch, into memory — the in-memory ``EntityStore`` is the source of truth.

For low-level manual wiring (writing your own `StateWriter` and `@Model`), see <doc:PersistenceMiddlewareGuide>. For the macro details, see <doc:MacrosReference>. To add cross-device iCloud sync on top, see <doc:HowToAddICloudSync>.

## Before you start

This guide assumes a Swidux app already exists — `AppState`, `AppAction`, `AppReducer`, and `AppStore` are wired and the store is in the SwiftUI environment. If not, follow <doc:GettingStarted> first.

`SwiduxPersistence` is a local-only persistence layer. It needs **no iCloud, CloudKit, or Push entitlements** — only the sandbox `com.apple.security.network.client` entitlement if your app also makes network calls (killswitch, analytics, feature flags). Adding sync entitlements to a local-only app is dead configuration and an App Review risk.

## Step 1: Add the dependency

Add the `SwiduxPersistence` product to your app target in `Package.swift`:

```swift
.target(
    name: "MyApp",
    dependencies: [
        "Swidux",
        "SwiduxPersistence",
    ]
)
```

## Step 2: Annotate your domain entity with `@Persisted`

A persisted entity is a value type that already satisfies `Identifiable & Equatable & Sendable` with `ID == UUID` (the ``EntityStore`` contract). Add `@Persisted`:

```swift
import SwiduxPersistence

@Persisted
nonisolated struct Card: Identifiable, Equatable, Sendable {
    var id: UUID
    var quote: String
    var createdAt: Date
}
```

This generates a `CardModel: @Model` class with `init(from:)` / `toDomain()` / `update(from:)`, plus `extension Card: PersistableEntity { typealias Model = CardModel }`. By default every stored property is mirrored directly onto the model — SwiftData persists scalars *and* `Codable` composites natively, so no manual blob columns are needed.

The generated model is **CloudKit-safe by construction**, so the *same* model backs both the local and the synced container (see <doc:HowToAddICloudSync>). SwiftData's CloudKit mirroring requires every non-optional attribute to be optional or carry a default value, and every relationship to be optional — validated when the `ModelContainer` is created. `@Persisted` satisfies this automatically:

- **Non-optional mirrored attributes get a default.** If you wrote one on the domain property (`var count: Int = 0`), it is propagated verbatim; otherwise the macro fills a canonical default for the known SwiftData primitives (`String → ""`, `Bool → false`, integers/floats `→ 0`, `Date → .distantPast`, `Data → Data()`, `UUID → UUID()`). Defaults are inert locally — `init(from:)` overwrites them on every load.
- **Non-primitive, non-optional properties** (a custom `Codable` type, `URL`, an enum) have no default the macro can invent. Give the property a default (`= …`), make it optional, or mark it `@Inline` — otherwise `@Persisted` emits a compile-time error.
- **Relationships are generated optional** (`var tags: [TagModel]? = nil`); a non-optional to-one `@Relation` is a compile-time error (CloudKit forbids non-optional relationships).
- **`@Inline` blob columns** default to `Data()`, so any `Codable` type is CloudKit-safe through `@Inline`.

`@Persisted` lives on the **entity**; `@Swidux` lives on **state containers** (`AppState`, `@Slice` slices). They are different layers and never apply to the same type.

### Marker macros for non-trivial properties

A macro can't infer relationships, foreign keys, or which fields are derived. Four property markers (named to avoid SwiftData's own `@Relationship`/`@Transient`) tell `@Persisted` what to do:

```swift
@Persisted
nonisolated struct Card: Identifiable, Equatable, Sendable {
    var id: UUID
    var quote: String

    @Inline var styling: TextStyling                 // one opaque JSON Data column
    @ForeignKey var deckID: UUID                      // scalar parent reference
    @Relation(deleteRule: .cascade, inverse: \TagModel.card)
    var tags: [Tag]                                   // SwiftData relationship
    @Ignored var renderedPreview: String?             // derived; omitted from the model
}
```

| Marker | Effect |
|---|---|
| *(none)* | Mirror the property directly (SwiftData persists scalars and `Codable` composites). |
| `@Inline` | Force a `Codable` value into a single JSON `Data` column (keeps a CloudKit record compact; sidesteps SwiftData `Codable`-attribute edge cases). |
| `@ForeignKey` | Intent marker on a `UUID`; functionally a mirrored scalar column. |
| `@Relation(deleteRule:inverse:)` | A SwiftData relationship to another `@Persisted` entity. The property's type references the *domain* type (`[Tag]` / `Tag?` / `Tag`); the model substitutes the `…Model` shadow. `inverse` is a key path on the generated model, e.g. `\TagModel.card`. `deleteRule` is a `SwiduxDeleteRule` (`.cascade`, `.nullify`, `.noAction`, `.deny`). |
| `@Ignored` | Exclude a derived/denormalized property. Must be optional so it can be reconstructed as `nil` on load. |

> Note: `@Persisted` does not generate an `@Attribute(.unique)` on `id` — CloudKit forbids unique constraints. Identity is enforced by upsert-by-`id` inside `EntityDB`, so the same generated model works for both local and synced containers.

## Step 3: Put the `EntityStore` on your state

```swift
@Swidux
nonisolated struct AppState: Equatable, Sendable {
    var cards: EntityStore<Card> = .init()
    // ... your other slices
}
```

Your reducers mutate `state.cards` like any ``EntityStore`` — `state.cards[card.id] = card`, `state.cards.modify(id) { … }`, `state.cards[id] = nil`. Every change is recorded for the plugin to drain.

## Step 4: Build the coordinator and register the plugin

In `Store.configured()`, build a local container, create a `PersistenceCoordinator`, register its plugin, and run first-load hydration before constructing the store:

```swift
import SwiduxPersistence

extension Store where State == AppState, Action == AppAction {
    static func configured() async -> AppStore {
        let container = try! ContainerFactory.makeLocalContainer(models: [CardModel.self])

        let persistence = PersistenceCoordinator<AppState, AppAction>(
            entities: [.entity(\.cards)],
            container: container,
            debounce: .milliseconds(250)
        )

        let plugins = PluginHost<AppState, AppAction>()
        // Register UndoPlugin first if you use it — snapshots must precede writes.
        plugins.register(persistence.corePlugin)

        var initial = AppState()
        await persistence.hydrate(into: &initial)   // first-load: fill EntityStores from disk

        return Store(initialState: initial, reducer: { … }, plugins: plugins)
    }
}
```

`hydrate(into:)` is **first-load only** — it replaces each ``EntityStore`` with the on-disk rows before any live edits exist. The only refresh path after launch is `rehydrate(into:)`, which always *merges* (preferring in-memory values) so a "refresh from disk" can never clobber unflushed writes or in-progress UI edits.

## Step 5: Flush on background

Writes are debounced, so drain them when the app is backgrounded or terminates:

```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .background {
        Task { await persistence.corePlugin.flush() }
    }
}
```

## Multiple entities and ordering

Register one `.entity(\.keyPath)` per ``EntityStore``:

```swift
let persistence = PersistenceCoordinator<AppState, AppAction>(
    entities: [.entity(\.decks), .entity(\.cards), .entity(\.tags)],
    container: try! ContainerFactory.makeLocalContainer(
        models: [DeckModel.self, CardModel.self, TagModel.self]
    )
)
```

Pass every generated `…Model` type to the container's `models:`. Writers flush in registration order — if entity B holds a `@Relation` to A, register A's entity first.

## Testing

The whole stack runs against an in-memory SwiftData store, so persistence is unit-testable with no disk and no CloudKit:

```swift
let container = try ContainerFactory.makeInMemoryContainer(models: [CardModel.self])
let db = EntityDB(modelContainer: container)

try await db.upsert(Card(id: id, quote: "hi", createdAt: .now), as: CardModel.self)
let all = try await db.fetchAll(CardModel.self)
#expect(all.first?.quote == "hi")
```

To prove the rule-#8 merge guarantee, seed the store, make a live in-memory edit, call `coordinator.rehydrate(into:)`, and assert the live edit survives.

## See Also

- <doc:HowToAddICloudSync>
- <doc:PersistenceMiddlewareGuide>
- <doc:EntityStoreGuide>
- <doc:MacrosReference>
