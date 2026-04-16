---
name: swidux-ref
description: "Swidux architecture reference (Redux-style unidirectional data flow for SwiftUI + SwiftData). MANDATORY when adding actions, modifying reducers, creating Effects, working with AppStore/AppState, EntityStore, PersistenceMiddleware, StateWriter, UndoMiddleware, change tracking, or scaffolding new apps. Also use for controlled components, form bindings with store-bound state, the effect system, and undo/redo. Activate on: 'scaffold', 'new project', 'create app', 'setup SwiftUI', 'add action', 'add reducer', 'modify reducer', 'dispatch', 'Swidux', 'EntityStore', 'persistence', 'controlled component', 'form binding', 'effect', 'StateWriter', 'undo', 'redo', 'UndoMiddleware'."
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
| `UndoMiddleware<State>` | Opt-in stack-based undo/redo for state snapshots |
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
            let item = Item(name: name)
            state.items[item.id] = item
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

### 9. Use the Snapshot Pattern in `send()` — No Manual Equality Guards
`@Observable` checks `Equatable` on plain assignment (`set` accessor) and suppresses notifications when values are unchanged. **Explicit equality guards are unnecessary.** However, Swift's `_modify` accessor (used by `inout`) fires notifications unconditionally. Always use the snapshot pattern: copy state out, mutate the copy, assign back.

```swift
// ✅ Snapshot pattern — `set` accessor checks equality automatically
var state = AppState(items: items, tags: tags, ui: ui)
reducer.reduce(state: &state, action: action, environment: environment)
items = state.items  // No notification if unchanged
ui = state.ui

// ❌ Never use inout on a stored @Observable property — _modify fires unconditionally
```

**Cross-slice isolation requires separate stored properties.** A view reading `store.items` won't re-render when `store.ui` changes. A single `var state: AppState` would invalidate all observers on every change. This is why `send()` must live in app code, not the framework.

### 10. Use `merge(from:preferExisting:)` for Re-hydration, Not Replacement
After initial startup, never assign a fresh `EntityStore(fromDB)` to a property — this destroys enriched in-memory state loaded lazily. Use `merge()` instead:

```swift
var merged = EntityStore(allFromDB)
// existing = entity from `existingStore` (the `from:` argument)
// incoming = entity already in `merged` (self)
// Return true to keep the `from:` entity, replacing the one in self
merged.merge(from: existingStore) { existing, incoming in
    existing.richData != nil && incoming.richData == nil
}
store.property = merged
```

### 11. Keep Reducers Lightweight
Reducers run synchronously on the MainActor. Any O(n²) work — nested loops, repeated linear scans, large sorts — blocks the UI thread until it completes. Move heavy computation into an `Effect` and dispatch the result back as an action.

### 12. Never Block Inside Effects
Effects run on Swift concurrency's cooperative thread pool (via `Task { @concurrent in }`). The pool has a small, fixed number of threads. **Synchronous blocking calls** inside an effect — `Process.waitUntilExit()`, `DispatchSemaphore.wait()`, `Thread.sleep()` — hold a thread hostage. If enough threads block, the pool starves and the MainActor freezes (beachball).

```swift
// ❌ Blocks a cooperative thread
process.run()
process.waitUntilExit()

// ✅ Yields the thread while waiting
try await withCheckedThrowingContinuation { continuation in
    process.terminationHandler = { _ in continuation.resume() }
    try process.run()
}
```

Common offenders: `Process.waitUntilExit()`, `DispatchSemaphore.wait()`, `Thread.sleep(forTimeInterval:)`, `Data(contentsOf:)` on large files.

---

## EntityStore API

`EntityStore<Entity>` works like a dictionary with insertion-order iteration. Entities must conform to `Identifiable & Equatable & Sendable` with `UUID` as the ID type.

```swift
var cards = EntityStore<Card>()

// Insert or update — always records an upsert, even if value is identical
cards[card.id] = card

// In-place mutation — recorded only if the value actually changes (checks Equatable)
// Prefer modify over subscript set when the transform might be a no-op
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

`modify` uses `Equatable` to skip recording when the transform doesn't change the value. `sort` only marks entities whose position actually changed — sorting an already-sorted store is a no-op for persistence. `removeAll(where:)` rebuilds the index once in O(n) rather than per-removal.

Every mutation is silently tracked in `changes: ChangeSet` (read-only property). The middleware drains changes via `resetChanges()` after each reducer call — you never call either of these yourself.

### restore(from:)

`restore(from:)` replaces all entities with those from a source store while recording the diff as changes for persistence. Used by undo/redo so the persistence middleware picks up the restored state.

```swift
// In applySnapshot (undo/redo):
var state = AppState(items: items, tags: tags, ui: ui)
state.items.restore(from: restored.items)  // records upserts + deletions
state.tags.restore(from: restored.tags)
state.ui = restored.ui                     // plain state — assign directly
persistence.afterReduce(state: &state)     // drains changes normally
```

Unlike `merge(from:)` (hydration, no changes recorded), `restore` records every difference.

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
    debounce: .milliseconds(250),  // Default; configurable
    loopThreshold: 100,            // Warns if afterReduce called this many times per debounce interval
    logger: environment.logger
)
```

The middleware tracks how many times `afterReduce` fires per debounce interval. If it exceeds `loopThreshold` (default 100), it logs a warning — this usually means `AppStore.send()` is not using the snapshot pattern from Rule #9, causing an infinite dispatch loop.

Call `persistence.afterReduce(state: &state)` after every reducer invocation from `AppStore.send()`.

### Explicit Flush on Shutdown

The debounce timer means writes can be buffered when the app terminates. Call `flush()` during shutdown to ensure no data is lost:

```swift
// In AppStore or App lifecycle:
await persistence.flush()
```

`flush()` cancels the active debounce timer and immediately persists all pending writes. Call it from `applicationWillTerminate`, `scenePhase == .background`, or any other shutdown path.

### Writer Ordering

> [!WARNING]
> **Writers flush sequentially in registration order (not in parallel).** If entity B holds a foreign-key reference to entity A, the writer for A **must** appear before the writer for B. Otherwise, B's upsert will look up A's row before it exists, silently dropping the relationship. Sequential flushing is what makes this ordering guarantee work.

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

## Undo/Redo

`UndoMiddleware<State>` is opt-in. It captures `AppState` snapshots before undoable actions and restores them on undo/redo. Memory-based (lost on relaunch), but restored state is persisted via `EntityStore.restore(from:)`.

```swift
@MainActor
public final class UndoMiddleware<State: Equatable & Sendable> {
    public init(maxDepth: Int = .max)

    public var canUndo: Bool
    public var canRedo: Bool

    /// Call before reducer for undoable actions.
    /// coalescing: true groups consecutive calls (e.g. keystrokes) into one entry.
    public func willReduce(state: State, coalescing: Bool = false)

    /// Returns restored state, or nil if stack is empty.
    public func undo(current: State) -> State?
    public func redo(current: State) -> State?
}
```

### Integration in AppStore

1. Add `undoMiddleware`, `canUndo`/`canRedo` observable properties
2. Classify actions with `isUndoable` and `isCoalescing` computed properties on `AppAction`
3. Call `undoMiddleware.willReduce(state:coalescing:)` before the reducer in `send()` for undoable actions
4. Add `undo()`/`redo()` methods using `applySnapshot()` with `EntityStore.restore(from:)`
5. Call `syncUndoState()` after every `send()`, `undo()`, and `redo()`
6. Wire platform UI: macOS `.commands { CommandGroup(replacing: .undoRedo) }`, iOS `UndoManager` bridge via `@Environment(\.undoManager)`

### Coalescing

`willReduce(coalescing: true)` pushes on the first call, skips subsequent consecutive coalescing calls. A non-coalescing call or undo/redo resets the flag. Use for per-keystroke text edits (`setName`, `rename`).

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
- `Effect<Action>` is a typealias for a `@Sendable` async closure. Reducers return plain closures; tests call them directly.

Return `nil` from the reducer when no effect is needed.

### Running Effects

Use `Task { @concurrent in }` to run effects off the MainActor. **Never use a bare `Task { }`** — inside an `@MainActor` class it inherits MainActor isolation, keeping the entire effect on the main thread.

```swift
// In AppStore.send():
if let effect {
    let send: Send = { [weak self] action in
        self?.send(action)
    }
    Task { @concurrent in
        await effect(send)
    }
}
```

---

## Threading Model (Swift 6.2+ Approachable Concurrency)

- **All isolation is explicit.** No implicit `DefaultIsolationMainActor` — each type declares its own isolation. AppStore, reducers, views, effect helpers are MainActor-isolated in app code.
- **Effects run off MainActor.** `Task { @concurrent in }` runs effect bodies on the cooperative thread pool. Dispatched actions hop back to MainActor via `Send`.
- **DB actors run off MainActor.** `@ModelActor` provides isolated `ModelContext`.
- **Minimize explicit `@MainActor`.** Only `AppStore` needs it explicitly in app code; the compiler infers the rest.
- **`nonisolated init`** on value types to allow creation from any context.
- `EntityStore` and `ChangeSet` are `nonisolated` value types conforming to `Sendable`.
- `StateWriter` and `PersistenceMiddleware` are both `@MainActor`-isolated (manage mutable buffers and a debounce `Task`).
- Package uses `.swiftLanguageMode(.v6)`.

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
