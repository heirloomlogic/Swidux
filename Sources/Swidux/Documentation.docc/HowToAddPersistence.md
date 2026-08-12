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
- **Relationships are generated optional** (`var tags: [TagModel]? = nil`); a non-optional to-one `@Relation` is a compile-time error (CloudKit forbids non-optional relationships). The generated `update(from:)` **reconciles related rows by `id`** — surviving identities are updated in place, new ones inserted, and departed ones deleted. It has to: a `deleteRule` fires when the *parent* is deleted, never when a child leaves the relationship, so rebuilding the set on each save would detach the previous rows rather than remove them and leave an orphan behind every time.
- **`@Inline` blob columns** default to `Data()`, so any `Codable` type is CloudKit-safe through `@Inline`. Because `Data()` is never decodable, a **non-optional** `@Inline` property must also carry a domain default (`= …`) — the generated getter falls back to it when the blob is missing or undecodable (e.g. a row CloudKit materialized before the blob synced). Omitting the default is a compile-time error (`inlineRequiresDefault`).

`@Persisted` lives on the **entity**; `@Swidux` lives on **state containers** (`AppState`, `@Slice` slices). They are different layers and never apply to the same type.

### Marker macros for non-trivial properties

A macro can't infer relationships, foreign keys, or which fields are derived. Four property markers (named to avoid SwiftData's own `@Relationship`/`@Transient`) tell `@Persisted` what to do:

```swift
@Persisted
nonisolated struct Card: Identifiable, Equatable, Sendable {
    var id: UUID
    var quote: String

    @Inline var styling: TextStyling = TextStyling()  // one opaque JSON Data column
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

> Note: `@Persisted` does not generate an `@Attribute(.unique)` on `id` — CloudKit forbids unique constraints — so the same generated model works for both local and synced containers. The cost is that rows sharing an `id` are possible. `EntityDB` handles them by converging rather than by assuming uniqueness: writes update every matching row, deletions remove every matching row, and `fetchAll` collapses to one value per `id`. Nothing deletes a duplicate as a side effect of a write.
>
> The one attribute it *does* generate is `@Attribute(.preserveValueOnDeletion)`, on `id` and nothing else, so that a deleted row's identity survives into persistent history where a peer device can read it. It needs no migration: the option leaves the entity's version hash alone, so stores written before it existed reopen unchanged.

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

Registering the plugin is all the wiring it needs. `Store` also finds it there for the two paths that drain *outside* the plugin lifecycle — `store.mutate { … }` and undo/redo — so you don't have to name it a second time as `persistencePlugin:`. (That parameter still exists, for draining through a plugin you deliberately didn't register.)

`hydrate(into:)` is **first-load only** — it replaces each ``EntityStore`` with the on-disk rows before any live edits exist. It takes `inout State` because it runs *before the store is built*, so there is nothing to race with.

The only refresh path after launch is `rehydrate(into:)`, which *reconciles* rather than replaces: rows on disk are authoritative except for IDs that still carry unflushed local intent, which always win. So a "refresh from disk" can never clobber pending writes or in-progress UI edits, while remote edits and deletions still surface mid-session. Pass `policy:` — or register an entity with `policy:` — to narrow that; see `MergePolicy` and <doc:HowToAddICloudSync>.

It takes the **store**, not `inout State`: re-hydration is asynchronous, and a caller holding a state snapshot across those `await`s would discard everything dispatched while they were in flight. See <doc:Troubleshooting> if edits are vanishing after a load.

If you need to *read* rows without touching state, don't re-hydrate into a throwaway `AppState()` — that idiom breaks silently the moment re-hydration starts reading the state it is handed. Use `fetchAll(of:)` / `snapshot(of:)` on the coordinator instead.

### Refreshing only the rows that changed

`rehydrate(into:)` re-reads every row of every registered entity. When something already told you *which* identities changed — a sync signal, a server push, a screen that knows what it just touched — `mergeRemote(into:ids:deleted:)` spends that knowledge instead of rediscovering it:

```swift
await persistence.mergeRemote(into: store, ids: changedIDs, deleted: tombstonedIDs)
```

One batched fetch per 500 IDs instead of a full-table scan, and only the named entities are reconciled — everything else in state is left exactly as it was. Every guarantee `rehydrate(into:)` makes still holds: pending writes flush first, and an ID with unflushed local intent always wins.

The one difference is deletions. A partial read can't tell a deleted row from one you simply didn't ask about, so this **never** infers a deletion — an ID vanishes only if you name it in `deleted:`, and only if the resolved policy allows removal. Name only what you have positive evidence for. In exchange there's no empty-snapshot guard to work around, so unlike `rehydrate(into:)` this *can* remove the last surviving entity.

A row an `editing` hold defers is remembered and re-offered on the next call, on top of whatever you name in `ids:`. You don't have to re-queue the ID yourself, which matters because the signal that named it is usually spent — so a hold delays a remote change here rather than vetoing it. `mergeChanges(into:)` shares the same debt, so either path delivers what the other deferred.

Two things it deliberately doesn't do: a registered `collapse:` resolver doesn't run (it judges the whole table, and a subset would have it judge a world it can't see — duplicates are still collapsed on read and still reported), and the ID set isn't keyed by entity type, so each registered entity pays one small round trip for IDs that turn out not to be its own.

When *nothing* told you which identities changed — the usual case for a CloudKit remote-change notification — `mergeChanges(into:)` works it out for itself from the store's persistent-history log and spends the result through the same path, falling back to a full `rehydrate(into:)` for any window it can't fully account for. See <doc:HowToAddICloudSync>.

### Persistent history

SwiftData records a transaction log for every file-backed store, whether or not you read it. `mergeChanges(into:)` is what reads it; nothing else trims it, so left alone it grows for the life of the app.

So the coordinator prunes it — transactions older than `historyRetention` (seven days by default) are deleted once per launch, from `hydrate(into:)`. Pass `historyRetention: nil` to turn that off, or call `pruneHistory(before:)` yourself.

A **CloudKit-mirrored store is never pruned**, whatever you pass. Mirroring reads the same log to decide what to export, there is no API to ask how far it has got, and deleting a transaction it hasn't exported yet resets the sync state and forces a full re-upload. Unpruned history is the status quo; a broken export isn't.

### Reading rows without touching state

For exports, migrations, diagnostics, or any other "what's actually on disk?" question, read directly — naming your domain type, not its generated shadow:

```swift
let notes = try await persistence.fetchAll(of: Note.self)
let store = try await persistence.snapshot(of: Note.self)   // as an EntityStore
let some  = try await persistence.fetch(ids: knownIDs, of: Note.self)   // just these
```

Both flush the debounce window first by default, so they can't return a stale row for something the user just edited; pass `flushPending: false` on a hot path where that doesn't matter. Both report failures to `onFailure` **and** rethrow — there is no state to leave untouched here, so swallowing the error could only present an unreadable database as "no data".

The entity does not have to be registered with the coordinator; reading a model that is in the container's schema but not mirrored into state is fine.

> Important: Don't answer these questions by re-hydrating into a throwaway `AppState()`. That reads like a pure fetch but is really a merge, and it breaks silently the moment re-hydration starts consulting the state it is handed.

### Surfacing failures

Every save and fetch failure is logged, and the coordinator accepts an optional `onFailure:` handler to additionally surface it to your app (a failed **save** means the in-memory data is *not* on disk; a failed **hydrate fetch** leaves that `EntityStore` untouched rather than presenting an unreadable store as "no data"):

```swift
let persistence = PersistenceCoordinator<AppState, AppAction>(
    entities: [.entity(\.cards)],
    container: container,
    onFailure: { failure in
        guard failure.isFinal else { return }   // earlier attempts may still succeed
        // e.g. dispatch an action that shows a "couldn't save" banner
    }
)
```

### Retrying a failed save

A flush clears its buffers before the save runs, so a save that fails has nothing left to retry it — the write would reach disk only if the user happened to touch the same entity again. That is silent data loss, so the stack retries.

A failed batch goes **back** into the writer's pending buffers, never over anything newer: a later edit to the same entity supersedes the restored value, and a deletion drained while the save was in flight cancels it. `PersistencePlugin` then re-attempts on a doubling backoff, independently of the debounce timer — a write has to land even if the user never touches the app again.

Retrying is bounded, because a write that can *never* succeed (disk full, a model the container can't encode) must not keep the stack busy forever. Tune it with `retry:`:

```swift
let persistence = PersistenceCoordinator<AppState, AppAction>(
    entities: [.entity(\.cards)],
    container: container,
    retry: RetryPolicy(maxAttempts: 5, baseDelay: .milliseconds(500), maxDelay: .seconds(30)),
    onFailure: { failure in ... }
)
```

`RetryPolicy.default` is that policy — five attempts over roughly seven seconds. `RetryPolicy.never` opts out of retrying without opting back into losing the write.

When the budget runs out you get one final `PersistenceFailure` with `isFinal == true`. That is the one worth telling the user about: everything before it was "we'll try again". The batch is **not** discarded — it stays pending, so the next edit or an explicit `flush()` tries once more, and until then those IDs stay locally owned so a re-hydration can't overwrite them with the stale stored row.

> Note: Every attempt is reported, so a handler that shows UI should gate on `isFinal`. Most `.save` failures are transient and are followed by a success the app never hears about.

### Diagnostics: what isn't a failure

Some conditions are worth acting on but aren't errors, so routing them through `onFailure` would be wrong. Duplicate rows are the clearest case: CloudKit forbids unique constraints, so several rows sharing an `id` are a legitimate on-disk state, not a fault. They go to `onDiagnostic:` instead:

```swift
let persistence = PersistenceCoordinator<AppState, AppAction>(
    entities: [.entity(\.cards, collapse: EntityCollapse.byID { $0.updatedAt >= $1.updatedAt ? $0 : $1 })],
    container: container,
    onDiagnostic: { diagnostic in
        guard diagnostic.kind == .duplicateRowsCollapsed,
              let count = diagnostic.duplicateCount else { return }
        store.send(.offerDuplicateCleanup(count: count))
    }
)
```

Seven kinds ship today:

| Kind | Means | Payload |
|---|---|---|
| `.duplicateRowsCollapsed` | A read found rows sharing an `id`. Without a `collapse:` resolver they are harmless but permanent — this is what lets you *offer* the cleanup. | `entityType`, `duplicateCount` |
| `.possibleDispatchLoop` | `afterReduce` fired far more often in one debounce interval than a user could cause. Usually an effect or plugin dispatching on every state change. Reported once per burst, not once per dispatch. | `drainCount` |
| `.writesUnpersisted` | The set of IDs whose last flush failed changed. Fires again with an **empty** set once they land, so an indicator can be cleared rather than guessed at. | `entityType`, `unpersistedIDs` |
| `.mergeWithheld` | A re-hydration left a stored value unapplied because an editing hold was in force. Expected while the user is editing; a hold that outlives the edit shows up here. See <doc:HowToAddICloudSync>. | `entityType`, `withheldIDs` |
| `.remoteChangesMerged` | A `mergeChanges(into:)` tick narrowed its work from persistent history and merged only the rows that changed. The healthy case — if it stops appearing, ticks have quietly gone back to reading every table. `carriedOverCount` counts how many of those rows an earlier tick had deferred and this one re-offered; equal to `mergedCount` tick after tick, no peer is writing and an editing hold has been leaked. | `mergedCount`, `carriedOverCount` |
| `.historyUnavailable` | A tick couldn't narrow its work and re-read every registered entity. Expected once per launch and after a container rebuild; repeatedly, the store can't be anchored at all, and `fallbackReason` says why. | `fallbackReason` |
| `.historyPruned` | Transactions older than `historyRetention` were deleted. Once per launch, never for a CloudKit-mirrored store. | `prunedCount` |

`PersistenceDiagnostic` is a struct with static constructors rather than an enum, so a future kind can't break an exhaustive `switch` in your code — match on `kind` and read the payload you expect. Duplicate reads and dispatch loops are logged whether or not you supply a handler; the unpersisted set has no log of its own, because the individual `PersistenceFailure`s behind it are already logged.

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
