---
name: swidux-ref
description: "Swidux architecture reference (Redux-style unidirectional data flow for SwiftUI + SwiftData). MANDATORY when adding actions, modifying reducers, creating Effects, working with AppStore/AppState, or scaffolding new apps. Activate on: 'scaffold', 'new project', 'create app', 'setup SwiftUI', 'add action', 'add reducer', 'modify reducer', 'dispatch', 'Swidux'."
---

# Swidux Architecture Reference

**Redux-style state management for SwiftUI + SwiftData.**

Swidux provides the persistence middleware layer for apps that use unidirectional data flow. Reducers mutate state, and Swidux automatically detects what changed and persists it — no explicit save calls, no load/loaded action pairs, no persistence boilerplate in feature code.

## What's in the Package

| Type | Purpose |
|------|---------|
| `EntityStore<Entity>` | Ordered, keyed collection with built-in change tracking |
| `ChangeSet` | Tracks which entity IDs were upserted or deleted |
| `StateWriter<State>` | Drains changelogs and accumulates batched persistence work |
| `PersistenceMiddleware<State>` | Debounced orchestrator that flushes writes after each reducer call |
| `Effect<Action>` / `Send<Action>` | Generic typealiases for the async effect system |
| `SwiduxReducer` | Protocol enforcing the reducer contract |
| `SwiduxDispatcher` | Protocol enforcing the store dispatch contract |

Everything else — state, actions, domain models, DB actors — lives in your app.

## Data Flow

```
View → store.send(.action)
  → Reducer mutates state (EntityStore tracks changes silently)
  → PersistenceMiddleware drains changelogs from EntityStores
  → StateWriters accumulate pending writes
  → Debounce timer fires → batched DB writes execute
  → View re-renders via @Observable
```

Key insight: **`EntityStore` records every mutation as it happens**. After each reducer call, the middleware drains these changelogs into `StateWriter` buffers. When the debounce timer fires (default 250ms), all pending writes flush in one batch. Rapid mutations naturally coalesce.

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│                 Your App                        │
│                                                 │
│  App/           AppStore: SwiduxDispatcher      │
│                 AppReducer: SwiduxReducer       │
│                 AppState, AppAction             │
│                 typealias Effect/Send           │
│                                                 │
│  Features/      Feature reducers: SwiduxReducer │
│  Models/        Domain value types + SwiftData  │
│  Services/      DB actors + external services   │
├─────────────────────────────────────────────────┤
│                 Swidux Package                  │
│                                                 │
│  Protocols      SwiduxReducer, SwiduxDispatcher │
│  Effect         Effect<Action>, Send<Action>    │
│  EntityStore    Change-tracked collections      │
│  ChangeSet      Mutation journal                │
│  StateWriter    Changelog → batched writes      │
│  Persistence    Debounced flush orchestrator    │
│  Middleware                                     │
└─────────────────────────────────────────────────┘
```

---

## Non-Negotiable Rules

### 1. Value Types in State via EntityStore — No @Query
Views render from `store.items.values` (value type arrays from `EntityStore`). **Never** use `@Query` in views. SwiftData models are internal to DB actors.

### 2. Struct Reducers Conforming to SwiduxReducer
Reducers are **structs** conforming to `SwiduxReducer`. They return `Effect?` — returning `nil` when no async work is needed.

```swift
struct ItemReducer: SwiduxReducer {
    func reduce(
        state: inout AppState,
        action: ItemAction,
        environment: AppEnvironment
    ) -> Effect? {
        switch action {
        case .create(let name):
            state.items[item.id] = Item(name: name)
        }
        return nil
    }
}
```

`SwiduxReducer` has separate `Action` and `RootAction` associated types — feature reducers handle a slice of actions but effects dispatch root-level actions.

### 3. State Updates Only in Reducers
**Never** mutate store properties from views or effects. Effects dispatch follow-up actions via `send`.

### 4. Persistence is Automatic — Never Call DB from Reducers
Reducers mutate `EntityStore` properties. The `PersistenceMiddleware` handles all DB writes automatically. **Never** call `db.save()` or `db.upsert()` from a reducer effect for EntityStore-managed data. Effects are only for non-persistence work: network calls, analytics, loading data.

### 5. Optimistic UI
State is updated synchronously in the reducer (instant UI feedback). Persistence happens asynchronously via the middleware. If a user taps rapidly, only the final state is persisted.

### 6. Controlled Components (No Local @State for Forms)
Form input (`TextField`, `Picker`, `Toggle`) is **store-bound** via `Binding(get:set:)`. Never use `@State` to buffer form input and sync with `onAppear`/`onChange`.

```swift
// ✅ Controlled — no local state
TextField("Title", text: Binding(
    get: { store.cards[cardID]?.title ?? "" },
    set: { store.send(.cards(.setTitle(cardID, $0))) }
))

// ❌ NEVER — local state + sync dance
@State private var text = ""
.onAppear { text = store.cards[cardID]?.title ?? "" }
.onChange(of: text) { store.send(.cards(.setTitle(cardID, $0))) }
```

Local `@State` is only valid for ephemeral UI mechanics: drag offsets, animation progress, popover flags.

### 7. Never Use Combine
Use `async/await`, `AsyncSequence`/`AsyncStream`, `Task`, and the `Effect` type.

### 8. Re-export Swidux from AppState
Use `@_exported import Swidux` in `AppState.swift` — no other file needs `import Swidux`.

```swift
@_exported import Swidux

struct AppState: Sendable {
    var items = EntityStore<Item>()
    var tags  = EntityStore<Tag>()
    var ui    = UIState()
}
```

### 9. Guard `@Observable` Writes in `send()` with Equality Checks
`@Observable` fires change notifications on every property `set`, even when the value is identical. Unconditional writes after every dispatch cause cascading SwiftUI re-renders that can create infinite loops. Always guard:

```swift
if items != state.items { items = state.items }
if ui != state.ui       { ui = state.ui }
```

### 10. Use `merge(from:preferExisting:)` for Re-hydration, Not Replacement
After initial startup, never assign a fresh `EntityStore(fromDB)` to a property — this destroys enriched in-memory state loaded lazily. Use `merge()` instead:

```swift
var merged = EntityStore(allFromDB)
merged.merge(from: existingStore) { existing, incoming in
    existing.richData != nil && incoming.richData == nil
}
store.property = merged
```

### 11. Keep Reducers Lightweight
Reducers run synchronously on the MainActor. Any O(n²) work — nested loops, repeated linear scans, large sorts — blocks the UI thread until it completes. Move heavy computation into an `Effect` and dispatch the result back as an action.

---

## EntityStore API

`EntityStore<Entity>` works like a dictionary with insertion-order iteration. Entities must conform to `Identifiable & Equatable & Sendable` with `UUID` as the ID type.

```swift
var cards = EntityStore<Card>()

// Insert or update — automatically recorded
cards[card.id] = card

// In-place mutation — automatically recorded
cards.modify(card.id) { $0.title = "New Title" }

// Delete — automatically recorded
cards[card.id] = nil

// Read
let card = cards[cardID]           // O(1) lookup
let all  = cards.values            // Insertion-ordered array
let n    = cards.count             // Count
let has  = cards.contains(cardID)  // Existence check

// Bulk
cards.sort { $0.sortIndex < $1.sortIndex }
cards.removeAll { $0.isArchived }

// Hydration (no changes recorded)
cards = EntityStore(arrayFromDB)
```

Every mutation is silently tracked in a `ChangeSet`. You never interact with the `ChangeSet` directly — the middleware drains it after each reducer call.

---

## Persistence Middleware

`PersistenceMiddleware<State>` is configured with `StateWriter` instances, one per `EntityStore`:

```swift
PersistenceMiddleware<AppState>(
    writers: [
        StateWriter(keyPath: \.tags) { writes, deletes in
            for tag in writes { try? await tagDB.upsert(tag) }
            for id in deletes { try? await tagDB.delete(id: id) }
        },
        StateWriter(keyPath: \.items) { writes, deletes in
            for item in writes { try? await itemDB.upsert(item) }
            for id in deletes  { try? await itemDB.delete(id: id) }
        },
    ],
    debounce: .milliseconds(250)  // Default; configurable
)
```

Call `persistence.afterReduce(state: &state)` after every reducer invocation from `AppStore.send()`.

### Writer Ordering

> [!WARNING]
> **Writers flush sequentially in registration order.** If entity B holds a foreign-key reference to entity A, the writer for A **must** appear before the writer for B. Otherwise, B's upsert will look up A's row before it exists, silently dropping the relationship.

The rule is **leaves first, aggregates last**:

```
images  →  flush first   (no foreign keys)
decks   →  flush second  (no image references)
cards   →  flush last    (references images via background)
```

Include a **defensive fallback** in upsert methods for cross-context timing:

```swift
// Safety net — create referenced entity inline if not found
private func findOrCreateImageAsset(_ asset: ImageAsset) throws -> ImageAssetModel {
    if let existing = try findImageAsset(asset.id) { return existing }
    let model = ImageAssetModel(from: asset)
    modelContext.insert(model)
    return model
}
```

---

## SwiduxReducer Protocol

```swift
public protocol SwiduxReducer<State, Action, RootAction, Environment> {
    associatedtype State
    associatedtype Action
    associatedtype RootAction
    associatedtype Environment

    func reduce(
        state: inout State,
        action: Action,
        environment: Environment
    ) -> Effect<RootAction>?
}
```

- **Root reducers**: `Action == RootAction == AppAction`
- **Feature reducers**: `Action = FeatureAction`, `RootAction = AppAction` — handle a slice but effects dispatch root actions.
- Return `nil` when no async work is needed (most cases). Return a single `nil` after the switch — only cases with effects return early.

## SwiduxDispatcher Protocol

```swift
public protocol SwiduxDispatcher<Action> {
    associatedtype Action
    func send(_ action: Action)
}
```

`AppStore` conforms to enforce the dispatch contract.

---

## Effect / Send

Swidux provides **generic** types. Your app specializes them:

```swift
// App/Effect.swift
typealias Send = Swidux.Send<AppAction>
typealias Effect = Swidux.Effect<AppAction>
```

- `Send<Action>` is `@MainActor @Sendable (Action) -> Void` — hops to MainActor for each dispatched action.
- `Effect<Action>` is a **struct** wrapping a `@Sendable` async closure. The body is `package`-access — downstream apps construct effects with `Effect { send in ... }` but cannot execute them directly.

Return `nil` from the reducer when no effect is needed.

### Running Effects with `runEffect`

`SwiduxDispatcher` provides a `runEffect(_:send:)` method that uses `Task { @concurrent in }` to run the effect body off the MainActor. **Never use a bare `Task { }` to run effects** — inside an `@MainActor` class, `Task { }` inherits MainActor isolation, defeating the purpose. The `package`-access body prevents this at compile time.

```swift
// In AppStore.send():
if let effect {
    let send: Send<AppAction> = { [weak self] action in
        self?.send(action)
    }
    runEffect(effect, send: send)
}
```

---

## Threading Model (Swift 6.2+ Approachable Concurrency)

- **MainActor is default.** Package uses `DefaultIsolationMainActor` experimental feature. AppStore, reducers, views, effect helpers are all MainActor-isolated.
- **Effects run off MainActor.** `runEffect(_:send:)` uses `Task { @concurrent in }` to run effect bodies on the cooperative thread pool. Dispatched actions hop back to MainActor via `Send`.
- **DB actors run off MainActor.** `@ModelActor` provides isolated `ModelContext`.
- **Minimize explicit `@MainActor`.** Only `AppStore` needs it explicitly in app code; the compiler infers the rest.
- **`nonisolated init`** on value types to allow creation from any context.
- `EntityStore` and `ChangeSet` are `nonisolated` value types conforming to `Sendable`.
- `PersistenceMiddleware` is `@MainActor`-isolated (manages a debounce `Task`).
- Package uses `.swiftLanguageMode(.v6)` + `.enableExperimentalFeature("DefaultIsolationMainActor")`.

---

## Naming Conventions

| Concept | Pattern | Example |
|---------|---------|---------|
| Value type | `{Type}` | `Card` |
| SwiftData model | `{Type}Model` | `CardModel` |
| DB actor | `{Type}DB` | `CardDB` |
| DB protocol | `{Type}DBProtocol` | `CardDBProtocol` |
| Reducer struct | `{Type}Reducer` | `CardReducer` |
| Feature action | `{Type}Action` | `CardAction` |

---

## Scaffolding a New Project

### Step 1: Gather Requirements
1. Project name
2. Target platforms (macOS, iOS, iPadOS, multi-platform)
3. App type (menu bar, standard window, document-based)

### Step 2: Add Swidux Package
Add `Swidux` as a local SPM package dependency.

### Step 3: Create Files in Order
1. `App/AppState.swift` — with `@_exported import Swidux`, `EntityStore` properties
2. `App/AppAction.swift` — root + feature action enums
3. `App/Effect.swift` — `typealias Effect = Swidux.Effect<AppAction>` / `typealias Send = Swidux.Send<AppAction>`
4. `App/AppEnvironment.swift`
5. `App/AppReducer.swift` — conforming to `SwiduxReducer`
6. `App/AppStore.swift` — conforming to `SwiduxDispatcher`, wiring `PersistenceMiddleware`
7. `App/{ProjectName}App.swift`
8. Feature reducers and views

### Step 4: New Feature Checklist
1. Value type in `Models/Domain/` — `Identifiable & Equatable & Sendable`, `nonisolated init`
2. SwiftData model in `Models/Persistence/` with `toDomain()` + `update(from:)`
3. DB actor in `Services/` with protocol and mock
4. `EntityStore<NewType>` property added to `AppState`
5. `{Feature}Action` enum added to `AppAction`
6. `{Feature}Reducer` struct conforming to `SwiduxReducer`
7. Wire reducer into `AppReducer`
8. Add `StateWriter(keyPath: \.newType)` to `PersistenceMiddleware` in `AppStore` — respect writer ordering
9. View reading `store.newType.values`, dispatching actions
10. Tests: reducer unit tests with mock DB

---

## Testing

- **Swift Testing** (`@Test`, `@Suite`) — never XCTest
- **Favor `internal` over `private`** for business logic to enable testing
- **Views verified via `#Preview`**, all business logic comprehensively tested
- Use `@Observable` (`@Environment(AppStore.self)`), never `@ObservableObject`

---

## Design Principles

### Feature Code Never Thinks About Persistence
Reducers mutate `EntityStore` properties on `AppState`. No `db.save()` calls, no `.loadItems` / `.itemsLoaded` action pairs, no debounce `Task` management. Persistence is fully automatic.

### Reducer Purity
Reducers are pure state transformations. They return `Effect?` for async work (network calls, analytics), but persistence is handled entirely by the middleware. Most reducer cases return `nil`.

---

## Requirements

- Swift 6.2+ / Xcode 26+
- macOS 15+ / iOS 18+

---

For code templates, see [swidux-patterns.md](swidux-patterns.md).
