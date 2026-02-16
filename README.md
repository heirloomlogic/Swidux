# Swidux

**Redux-style state management for SwiftUI + SwiftData.**

Swidux is a persistence middleware layer for apps that use unidirectional data flow. Reducers mutate state, and the middleware detects what changed and persists it. This removes the need for explicit save calls, load/loaded action pairs, and persistence boilerplate in feature code.

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

Your state, actions, domain models, and DB actors live in your app. Swidux provides the contracts and persistence plumbing.

## How It Works

```
View → store.send(.action)
  → Reducer mutates state (EntityStore tracks changes silently)
  → PersistenceMiddleware drains changelogs from EntityStores
  → StateWriters accumulate pending writes
  → Debounce timer fires → batched DB writes execute
  → View re-renders via @Observable
```

`EntityStore` records every mutation as it happens — inserts, updates, and deletes. After each reducer call, the middleware drains these changelogs into `StateWriter` buffers. When the debounce timer fires (default 250ms), all pending writes flush in one batch. Rapid mutations coalesce: if a card is updated 10 times in 200ms, only the final state hits the database.

## Architecture Overview

Swidux is the persistence layer. Here's the boundary between package and app:

```
┌─────────────────────────────────────────────────┐
│                 Your App                        │
│                                                 │
│  App/           AppStore: SwiduxDispatcher      │
│                 AppReducer: SwiduxReducer       │
│                 AppState, AppAction, Effect     │
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

## Adopting Swidux in a New App

### 1. Add the Package

Add `Swidux` as a local package dependency in your Xcode project.

### 2. Re-export from AppState

In your `AppState.swift`, use `@_exported import`:

```swift
import Foundation
@_exported import Swidux

struct AppState: Sendable {
    var items = EntityStore<Item>()
    var tags  = EntityStore<Tag>()
    var ui    = UIState()
}
```

This makes all Swidux types (`EntityStore`, `SwiduxReducer`, `SwiduxDispatcher`, `Effect`, `Send`, etc.) visible throughout your app without additional imports. You won't write `import Swidux` in a feature file.

### 3. Define the App-Side Types

Swidux expects your app to provide these types. They are app-specific because they reference your domain models and actions.

#### Effect + Send

```swift
// App/Effect.swift

/// Concrete typealiases specializing Swidux's generic effect system.
typealias Send = Swidux.Send<AppAction>
typealias Effect = Swidux.Effect<AppAction>
```

The package provides generic `Send<Action>` and `Effect<Action>`. Your app specializes them with your action type. Reducer return types (`-> Effect?`) work from there.

#### AppAction

```swift
// App/AppAction.swift

enum AppAction: Sendable {
    case items(ItemAction)
    case tags(TagAction)
    // ... feature actions
}
```

#### AppReducer

```swift
// App/AppReducer.swift

struct AppReducer: SwiduxReducer {
    let itemReducer = ItemReducer()
    let tagReducer  = TagReducer()
    
    let itemDB: any ItemDBProtocol
    let tagDB:  any TagDBProtocol

    func reduce(
        state: inout AppState,
        action: AppAction,
        environment: AppEnvironment
    ) -> Effect? {
        switch action {
        case .items(let action):
            return itemReducer.reduce(state: &state, action: action, environment: environment)
        case .tags(let action):
            return tagReducer.reduce(state: &state, action: action, environment: environment)
        }
    }
}
```

The root reducer conforms with `Action = RootAction = AppAction`.

#### Feature Reducers

Feature reducers also conform to `SwiduxReducer`. They handle feature-specific actions but return `Effect?` (which is `Effect<AppAction>?`):

```swift
struct ItemReducer: SwiduxReducer {
    func reduce(
        state: inout AppState,
        action: ItemAction,
        environment: AppEnvironment
    ) -> Effect? {
        // ...
    }
}
```

`SwiduxReducer` has separate `Action` and `RootAction` associated types for this. Feature reducers handle a slice of actions; effects dispatch root-level actions.

#### AppStore

```swift
// App/AppStore.swift

@Observable
final class AppStore: SwiduxDispatcher {
    private(set) var items = EntityStore<Item>()
    private(set) var tags  = EntityStore<Tag>()
    private(set) var ui    = UIState()
    
    private let reducer: AppReducer
    private let persistence: PersistenceMiddleware<AppState>

    init(environment: AppEnvironment, reducer: AppReducer) {
        self.reducer = reducer
        self.persistence = PersistenceMiddleware(
            // ⚠️ Leaf entities first — see "Writer Ordering" below
            writers: [
                StateWriter(keyPath: \.tags) { [reducer] writes, deletes in
                    for tag in writes { try? await reducer.tagDB.upsert(tag) }
                    for id in deletes { try? await reducer.tagDB.delete(id: id) }
                },
                StateWriter(keyPath: \.items) { [reducer] writes, deletes in
                    for item in writes { try? await reducer.itemDB.upsert(item) }
                    for id in deletes  { try? await reducer.itemDB.delete(id: id) }
                },
            ]
        )
    }

    func send(_ action: AppAction) {
        var state = AppState(items: items, tags: tags, ui: ui)

        let effect = reducer.reduce(
            state: &state, action: action, environment: environment
        )

        persistence.afterReduce(state: &state)

        self.items = state.items
        self.tags  = state.tags
        self.ui    = state.ui

        if let effect {
            Task { [weak self] in
                await effect { action in self?.send(action) }
            }
        }
    }
}
```

`SwiduxDispatcher` conformance enforces that `send(_:)` exists with the correct signature.

### 4. Wire Up Views

Views read from the store and dispatch actions. They don't import Swidux, don't touch the DB, and don't see SwiftData models:

```swift
struct ItemListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List(store.items.values) { item in
            Text(item.name)
        }
        .toolbar {
            Button("Add") { store.send(.items(.create)) }
        }
    }
}
```

## EntityStore API

`EntityStore<Entity>` works like a dictionary with insertion-order iteration:

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
```

Every mutation is tracked in a `ChangeSet`. You don't interact with the `ChangeSet` directly; the middleware drains it after each reducer call.

### Entity Requirements

Entities must conform to `Identifiable`, `Equatable`, and `Sendable`, with `UUID` as the ID type:

```swift
struct Card: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var sortIndex: Int

    nonisolated init(id: UUID = UUID(), title: String, sortIndex: Int = 0) {
        self.id = id
        self.title = title
        self.sortIndex = sortIndex
    }
}
```

The `nonisolated init` is required for Swift 6 Approachable Concurrency to allow creation from any actor context.

## Persistence Middleware

`PersistenceMiddleware<State>` is configured with `StateWriter` instances, one per `EntityStore` in your state:

```swift
PersistenceMiddleware<AppState>(
    writers: [
        StateWriter(keyPath: \.items) { writes, deletes in
            // Called when the debounce timer fires
            for item in writes { try? await db.upsert(item) }
            for id in deletes  { try? await db.delete(id: id) }
        },
    ],
    debounce: .milliseconds(250)  // Default; configurable
)
```

Call `persistence.afterReduce(state: &state)` after every reducer invocation. It:

1. **Drains** changelogs from each `EntityStore` (sub-microsecond, synchronous)
2. **Coalesces** later writes for the same ID, overwriting earlier ones
3. **Debounces** by restarting a timer on each drain and flushing when it fires
4. **Batches** all pending writes into a single async Task

### Writer Ordering

> [!WARNING]
> **Writers flush sequentially in registration order.** If entity B holds a foreign-key reference to entity A, the writer for A **must** appear before the writer for B. Otherwise, B's upsert will try to look up A's row before it exists, silently dropping the relationship.

Leaf entities first, aggregates last:

```
images  →  flush first   (no foreign keys)
decks   →  flush second  (no image references)
cards   →  flush last    (references images via background)
```

Your `upsert` methods should include a defensive fallback: if a referenced entity isn't found, create it inline from the domain data rather than setting the relationship to `nil`. This covers timing issues between separate `@ModelActor` contexts.

```swift
// In CardDB — safety net for cross-context timing
private func findOrCreateImageAsset(_ asset: ImageAsset) throws -> ImageAssetModel {
    if let existing = try findImageAsset(asset.id) { return existing }
    let model = ImageAssetModel(from: asset)
    modelContext.insert(model)
    return model
}
```

## Design Principles

### Feature Code Never Thinks About Persistence

Reducers mutate `EntityStore` properties on `AppState`. No `db.save()` calls, no `.loadItems` / `.itemsLoaded` action pairs, no debounce `Task` management. Persistence is automatic.

### Optimistic UI

State updates synchronously in the reducer, giving instant UI feedback. Persistence happens asynchronously. If a user taps rapidly, only the final state is persisted.

### Controlled Components

Form inputs are store-bound via `Binding(get:set:)`. No `@State` buffering, no `onAppear`/`onChange` sync. The store is the single source of truth.

### Reducer Purity

Reducers are pure state transformations. They return `Effect?` for async work (network calls, analytics, etc.), but persistence is handled by the middleware. Most reducer cases return `nil`.

## Swift 6 Compatibility

Swidux targets Swift 6 with strict concurrency.

- `EntityStore` and `ChangeSet` are `nonisolated` value types conforming to `Sendable`
- `PersistenceMiddleware` is `@MainActor`-isolated (it manages a debounce `Task`)
- `StateWriter` is a reference type with closure-captured state
- The package uses `.swiftLanguageMode(.v6)` in its manifest

## Requirements

- Swift 6.2+ / Xcode 26+
- macOS 15+ / iOS 18+
