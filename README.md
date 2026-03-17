# Swidux

**Redux-style state management for SwiftUI + SwiftData.**

Swidux is a persistence middleware layer for apps that use unidirectional data flow. Reducers mutate state, and the middleware detects what changed and persists it. You don't write save calls, load/loaded action pairs, or persistence code in features.

## What's in the Package

| Type | Purpose |
|------|---------|
| `EntityStore<Entity>` | Ordered, keyed collection with built-in change tracking |
| `ChangeSet` | Tracks which entity IDs were upserted or deleted |
| `StateWriter<State>` | Drains changelogs and accumulates batched persistence work |
| `PersistenceMiddleware<State>` | Debounced orchestrator that flushes writes after each reducer call |
| `UndoMiddleware<State>` | Opt-in stack-based undo/redo for state snapshots |
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

`EntityStore` records every mutation as it happens. After each reducer call, the middleware drains these changelogs into `StateWriter` buffers. When the debounce timer fires (default 250ms), all pending writes flush in one batch. Rapid mutations coalesce: if a card is updated 10 times in 200ms, only the final state hits the database.

## Getting Started

### 1. Add the Package

**Xcode:** File > Add Package Dependencies, paste `https://github.com/heirloomlogic/Swidux`, set **Up to Next Major** from `1.0.0`.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/heirloomlogic/Swidux", from: "1.0.0"),
]
```

### 2. Define Your Types

Re-export Swidux from `AppState.swift` so no other file needs `import Swidux`:

```swift
// App/AppState.swift
import Foundation
@_exported import Swidux

struct AppState: Sendable {
    var items = EntityStore<Item>()
    var tags  = EntityStore<Tag>()
    var ui    = UIState()
}
```

Specialize the generic effect system with your action type:

```swift
// App/Effect.swift
typealias Send = Swidux.Send<AppAction>
typealias Effect = Swidux.Effect<AppAction>
```

- `Send<Action>` is `@MainActor @Sendable (Action) -> Void` — dispatched actions hop back to the MainActor.
- `Effect<Action>` is a `@Sendable` async closure. Run with `Task { @concurrent in }` to stay off the MainActor.

Define your action tree and root reducer:

```swift
// App/AppAction.swift
enum AppAction: Sendable {
    case items(ItemAction)
    case tags(TagAction)
}

// App/AppReducer.swift
struct AppReducer: SwiduxReducer {
    let itemReducer = ItemReducer()
    let tagReducer  = TagReducer()

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

Feature reducers conform to `SwiduxReducer` with `Action = FeatureAction` and `RootAction = AppAction`. Return `nil` when no async work is needed:

```swift
struct ItemReducer: SwiduxReducer {
    func reduce(state: inout AppState, action: ItemAction, environment: AppEnvironment) -> Effect? {
        switch action {
        case .increment(let id):
            state.items.modify(id) { $0.count += 1 }
        }
        return nil
    }
}
```

### 3. Wire the AppStore

`AppStore` owns separate stored properties per state slice so `@Observable` tracks each one independently. `send()` uses the **snapshot pattern** (see [The Snapshot Pattern](#the-snapshot-pattern)):

```swift
@Observable
final class AppStore: SwiduxDispatcher {
    private(set) var items = EntityStore<Item>()
    private(set) var tags  = EntityStore<Tag>()
    private(set) var ui    = UIState()

    private let reducer: AppReducer
    private let persistence: PersistenceMiddleware<AppState>

    func send(_ action: AppAction) {
        var state = AppState(items: items, tags: tags, ui: ui)
        let effect = reducer.reduce(state: &state, action: action, environment: environment)
        persistence.afterReduce(state: &state)
        items = state.items
        tags = state.tags
        ui = state.ui

        if let effect {
            let send: Send = { [weak self] action in self?.send(action) }
            Task { @concurrent in await effect(send) }
        }
    }
}
```

### 4. Wire Views

Views read from the store and dispatch actions. They don't import Swidux or touch the database:

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

`EntityStore<Entity>` works like a dictionary with insertion-order iteration. Entities must conform to `Identifiable & Equatable & Sendable` with `UUID` as the ID type.

```swift
var cards = EntityStore<Card>()

cards[card.id] = card                      // Insert or update — recorded
cards.modify(card.id) { $0.title = "New" } // In-place — recorded only if value changes
cards[card.id] = nil                       // Delete — recorded

let card = cards[cardID]                   // O(1) lookup
let all  = cards.values                    // Insertion-ordered array

cards.sort { $0.sortIndex < $1.sortIndex } // Only marks moved entities
cards.removeAll { $0.isArchived }          // Rebuilds index in one pass
```

Every mutation is tracked in a `ChangeSet` that the middleware drains after each reducer call.

### Merging (Re-hydration)

Replacing an `EntityStore` after startup destroys any in-memory state that was loaded lazily after initial hydration. Use `merge(from:preferExisting:)` instead:

```swift
var merged = EntityStore(allFromDB)
merged.merge(from: existingStore) { existing, incoming in
    existing.calculationState != nil && incoming.calculationState == nil
}
campaigns = merged
```

`merge` does not record changes — it has hydration semantics like `init(_:)`.

### restore(from:)

`restore(from:)` replaces all entities with those from the source store while recording the diff as changes for persistence. Used by undo/redo (see [Undo/Redo](#undoredo)).

- **Deletions** — IDs in self but absent from source
- **Upserts** — IDs that are new or whose values differ
- **Unchanged** — identical values produce no change records

## Persistence Middleware

`PersistenceMiddleware<State>` is configured with one `StateWriter` per `EntityStore`:

```swift
PersistenceMiddleware<AppState>(
    writers: [
        StateWriter(keyPath: \.items) { writes, deletes in
            for item in writes { try? await db.upsert(item) }
            for id in deletes  { try? await db.delete(id: id) }
        },
    ],
    debounce: .milliseconds(250)  // Default; configurable
)
```

Call `persistence.afterReduce(state: &state)` after every reducer invocation. It drains changelogs, coalesces writes per ID, debounces, and batches all pending writes into a single async Task.

Call `await persistence.flush()` on shutdown (`scenePhase == .background`, `applicationWillTerminate`) to ensure buffered writes aren't lost.

### Writer Ordering

> [!WARNING]
> **Writers flush sequentially in registration order.** If entity B references entity A via foreign key, A's writer **must** come first. Otherwise B's upsert looks up A's row before it exists.

Register leaf entities first, aggregates last. Include a defensive fallback in upsert methods — if a referenced entity isn't found, create it inline rather than setting the relationship to `nil`.

## Undo/Redo

`UndoMiddleware<State>` is an opt-in undo/redo stack. It captures state snapshots before each undoable action. Undo history lives in memory (lost on relaunch), but restored state is persisted normally via `EntityStore.restore(from:)`.

If you don't use `UndoMiddleware`, nothing changes.

### Adding Undo to Your App

**1. Create the middleware** in AppStore:

```swift
private let undoMiddleware = UndoMiddleware<AppState>()          // unlimited depth
private let undoMiddleware = UndoMiddleware<AppState>(maxDepth: 50) // or capped
```

**2. Classify actions.** Decide which are undoable and which coalesce (grouping rapid calls like per-keystroke text edits into one undo step):

```swift
extension AppAction {
    var isUndoable: Bool {
        switch self {
        case .items(.create), .items(.delete), .items(.rename): true
        case .selectItem, .toggleSidebar: false
        }
    }

    var isCoalescing: Bool {
        switch self {
        case .items(.rename): true
        default: false
        }
    }
}
```

**3. Snapshot in `send()`.** Call `willReduce` before the reducer runs:

```swift
func send(_ action: AppAction) {
    let current = AppState(items: items, tags: tags, ui: ui)
    if action.isUndoable {
        undoMiddleware.willReduce(state: current, coalescing: action.isCoalescing)
    }
    var state = current
    // ... reducer, persistence, assign-back as normal
}
```

**4. Add undo/redo methods.** Use `restore(from:)` so changes flow through persistence:

```swift
func undo() {
    let current = AppState(items: items, tags: tags, ui: ui)
    guard let restored = undoMiddleware.undo(current: current) else { return }
    applySnapshot(restored)
}

func redo() {
    let current = AppState(items: items, tags: tags, ui: ui)
    guard let restored = undoMiddleware.redo(current: current) else { return }
    applySnapshot(restored)
}

private func applySnapshot(_ restored: AppState) {
    var state = AppState(items: items, tags: tags, ui: ui)
    state.items.restore(from: restored.items)  // records diff for persistence
    state.tags.restore(from: restored.tags)
    state.ui = restored.ui                     // plain state — assign directly
    persistence.afterReduce(state: &state)
    items = state.items
    tags = state.tags
    ui = state.ui
}
```

**5. Expose `canUndo`/`canRedo`** as observable properties. Call `syncUndoState()` after every `send()`, `undo()`, and `redo()`.

**6. Wire platform UI:**

```swift
// macOS — replace Edit menu
WindowGroup { ... }
.commands {
    CommandGroup(replacing: .undoRedo) {
        Button("Undo") { store.undo() }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!store.canUndo)
        Button("Redo") { store.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!store.canRedo)
    }
}

// iOS — bridge system UndoManager for shake-to-undo
// In AppStore:
weak var undoManager: UndoManager?
// Register after undoable send():  undoManager?.registerUndo(withTarget: self) { $0.undo() }
// Register after undo():           undoManager?.registerUndo(withTarget: self) { $0.redo() }
// Register after redo():           undoManager?.registerUndo(withTarget: self) { $0.undo() }

// In view — connect the environment UndoManager:
.onAppear { store.undoManager = undoManager }
.onChange(of: undoManager) { _, new in store.undoManager = new }
```

### Coalescing

`willReduce(coalescing: true)` pushes on the first call, then skips subsequent consecutive coalescing calls — they share the original snapshot. A non-coalescing call or undo/redo resets the flag. Typing "hello" produces one undo entry, not five.

### Memory

Each snapshot is a value-type copy of `AppState`. Cost is proportional to the number of entities across all stores. Use `maxDepth` to bound memory for large state.

## Architecture & Performance

### The Snapshot Pattern

`send()` copies stored properties into a local `AppState`, mutates the copy via the reducer, then assigns back. This is required for two reasons:

1. **`@Observable` equality checking.** The `set` accessor checks `Equatable` and suppresses no-op notifications. Swift's `_modify` accessor (used by `inout`) fires notifications unconditionally. The snapshot pattern routes through `set`.

2. **Cross-slice observation isolation.** Separate stored properties (`var items`, `var tags`, `var ui`) mean a view reading `store.items` won't re-render when only `store.ui` changes. A single `var state: AppState` would invalidate all observers on every dispatch.

Because the stored properties are app-specific, `send()` cannot be provided by the framework — it must be written in each app's `AppStore`.

> [!NOTE]
> Explicit equality guards (`if x != state.x { x = state.x }`) are unnecessary. `@Observable` already checks equality on `set`. Unconditional assignment is safe.

### Dispatch Loop Detection

`PersistenceMiddleware` warns if `afterReduce` is called more than 100 times per debounce interval. This usually means `send()` isn't using the snapshot pattern, causing cascading re-renders that trigger re-dispatches.

### Reducer Weight

Reducers run synchronously on the MainActor. Move O(n²) work into an `Effect` and dispatch the result back as an action.

### Effect Threading

> [!CAUTION]
> Effects run on Swift concurrency's cooperative thread pool via `Task { @concurrent in }`. Blocking calls (`Process.waitUntilExit()`, `DispatchSemaphore.wait()`, `Thread.sleep()`) hold threads hostage. If enough block, the pool starves and the MainActor freezes.

Use async alternatives: `terminationHandler` + continuation instead of `waitUntilExit()`, `Task.sleep()` instead of `Thread.sleep()`, async file I/O instead of `Data(contentsOf:)`.

## Design Principles

Persistence is invisible. Reducers mutate `EntityStore` properties; the middleware handles `db.save()` and load/loaded action pairs. State updates synchronously in the reducer for instant feedback, and persistence happens asynchronously (rapid taps coalesce). Form inputs bind to the store via `Binding(get:set:)` rather than `@State` buffering. Reducers are pure state transformations that return `Effect?` for async work.

## Requirements

- Swift 6.2+ / Xcode 26+, macOS 15+ / iOS 18+
- Strict concurrency (`.swiftLanguageMode(.v6)`). All isolation is explicit. `EntityStore` and `ChangeSet` are `nonisolated` value types; `StateWriter`, `PersistenceMiddleware`, and `UndoMiddleware` are `@MainActor`-isolated.
