---
name: swidux-ref
description: Architecture rules and code templates for Swidux — a Redux-style state-management library for SwiftUI. Use when writing Swidux apps, adding actions or reducers, wiring plugins (Persistence, Undo, Killswitch, ParentalGate, Paywall), or designing state with @SwiduxState. Activate on "Swidux", "@SwiduxState", "AppStore", "AppState", "AppReducer", "EntityStore", "PersistencePlugin", "UndoPlugin", "killswitch", "paywall", "parental gate".
---

# Swidux Reference

Swidux is a Redux-style state-management library for SwiftUI. State lives in one observable store; mutations go through reducers; side effects run as async closures. Macros generate observability boilerplate; plugins handle persistence, undo, paywalls, killswitches, and parental gates.

This skill captures the rules, conventions, and dispatch lifecycle. Code templates are in `swidux-patterns.md`.

## The 10 architecture rules

### 1. State is a `nonisolated` struct annotated with `@SwiduxState`

```swift
@SwiduxState
nonisolated struct AppState: Equatable, Sendable {
    var items: EntityStore<Item> = .init()
    @SwiduxNested var ui: UIState = .init()
}
```

The macro emits an `@Observable` companion class (`AppStateObserver`) and a `SwiduxObservable` extension with `init(observer:)`, `makeObserver(from:)`, `apply(_:to:)`, and `applyRestore(from:to:)`. Don't hand-write the observer. Mark nested struct properties with `@SwiduxNested` so they get their own observer class for per-property observation.

### 2. Actions are `Sendable` enums, never `async` and never `throws`

```swift
enum AppAction: Sendable {
    case items(ItemAction)
    case selectItem(UUID?)
}
```

Async work lives in effects, not in actions. Action cases describe events and intents; the reducer translates them into state mutations and optional effects.

### 3. Reducers are pure and synchronous

```swift
struct AppReducer: SwiduxReducer {
    func reduce(state: inout AppState, action: AppAction, environment: AppEnvironment) -> Effect? {
        switch action {
        case .selectItem(let id):
            state.ui.selectedItemID = id
            return nil
        }
    }
}
```

Mutate state in place. Return `Effect?` — `nil` if no async work, or a closure that does I/O and dispatches follow-up actions. Never call `await` from inside a reducer body. Never throw.

### 4. Effects run off the MainActor; sends hop back

```swift
typealias Send = Swidux.Send<AppAction>      // @MainActor @Sendable (AppAction) -> Void
typealias Effect = Swidux.Effect<AppAction>  // @Sendable (Send) async -> Void
```

The `Store` runs effects with `Task { @concurrent in }` to keep them off the MainActor. The `send` callback inside an effect is `@MainActor`, so dispatching back happens on MainActor automatically. Specialize `Send` and `Effect` once for your `AppAction`.

### 5. The store is a typealias and an extension

```swift
typealias AppStore = Store<AppState, AppAction>

extension Store where State == AppState, Action == AppAction {
    static func configured(environment: AppEnvironment = .live()) -> AppStore { … }
}
```

Don't subclass `Store`. Compose it through a configuration extension that registers plugins and returns the wired instance.

### 6. Plugins are the single extension point

The `SwiduxPlugin` protocol has four hooks (all default no-op):

| Hook | When | Use for | Returns |
|---|---|---|---|
| `willReduce(state:action:)` | Before app reducer | Snapshots, pre-mutation analytics | `Void`, read-only state |
| `reduce(state:action:) -> Effect?` | After app reducer | Domain logic, async work | Optional effect |
| `afterReduce(state:action:)` | After all reducing | Persistence drain, logging | `Void` |
| `flush() async` | App shutdown | Drain async buffers | `Void` |

**Core middleware** (`PersistencePlugin`, `UndoPlugin`) is action-agnostic — works with any app, no wiring beyond construction. **Domain plugins** (`KillswitchPlugin`, `ParentalGatePlugin`, `PaywallPlugin`) own a state slice and action enum and require keypath + action lifter + extractor.

### 7. The dispatch lifecycle is fixed

For every `store.send(action)`:

```
1. pack:        observer tree → state struct snapshot
2. willReduce:  plugins observe pre-state (UndoPlugin snapshots here)
3. reducer:     app reducer mutates state, may return Effect
4. plugins.reduce: domain plugins handle their actions, may return Effects
5. afterReduce: plugins observe post-state (PersistencePlugin drains here)
6. unpack:      diff state vs observer tree, assign only changed properties
7. effects:     each Effect runs in Task { @concurrent in }
```

Per-property observation is preserved by step 6: only changed properties are written back to the observer tree, so SwiftUI views only re-render the parts they read.

### 8. Persistence is automatic via `EntityStore` change tracking

```swift
let persistencePlugin = PersistencePlugin<AppState, AppAction>(
    writers: [
        StateWriter(keyPath: \.items) { writes, deletes in
            for item in writes { try? await db.upsert(item) }
            for id in deletes { try? await db.delete(id: id) }
        }
    ]
)
```

`EntityStore.modify(_:_:)`, `removeAll(where:)`, and `sort(by:)` track changes. The plugin debounces and batches them; you never call `save()` from a reducer. Reducers stay pure; persistence is observed.

**Scalar preferences (UserDefaults) use a different mechanism.** `EntityStore` is for collections of identifiable entities. For one-off scalar values (theme, sort order, last-seen version), inject a `KeyValueStore` through `Environment`, declare type-safe keys on `KVKey`, hydrate state at startup, and write from effects:

```swift
extension KVKey where Value == Theme {
    static let theme = KVKey<Theme>("theme")
}

struct AppEnvironment: Sendable {
    var keyValue: any KeyValueStore  // production: UserDefaultsKeyValueStore()

    static func live() -> Self { .init(keyValue: UserDefaultsKeyValueStore()) }
}

extension AppState {
    static func hydrated(from store: any KeyValueStore) -> AppState {
        AppState(theme: store.value(.theme) ?? .system)
    }
}

// Reducer arm — no try?, no throws. Encode errors are logged + assertionFailure in DEBUG.
case .themeChanged(let theme):
    state.theme = theme
    return { @Sendable _ in
        environment.keyValue.setValue(theme, for: .theme)
    }
```

Reads are for **hydration only** — don't read from a reducer mid-cycle. Tests inject `InMemoryKeyValueStore`. Values are JSON-encoded as `Data`, so `@AppStorage` cannot observe them (intentional — Swidux state is the source of truth).

### 9. Undo is opt-in via `UndoPlugin`

```swift
let undoPlugin = UndoPlugin<AppState, AppAction>(
    isUndoable: { action in
        if case .items(.add) = action { return true }
        if case .items(.remove) = action { return true }
        return false
    },
    coalescing: { action in
        if case .items(.setName) = action { return true }  // collapse keystrokes
        return false
    }
)
```

`isUndoable` filters which actions snapshot. `coalescing` collapses bursts of the same action class into a single undo step (typically text edits). On macOS, hook `store.undo()` / `store.redo()` into `CommandGroup(replacing: .undoRedo)`.

### 10. Plugin registration order matters at the boundaries

```swift
let plugins = PluginHost<AppState, AppAction>()
plugins.register(undoPlugin)         // 1. snapshots in willReduce — must run before mutation
plugins.register(persistencePlugin)  // 2. drains in afterReduce — wants final state
plugins.register(killswitchPlugin)   // 3. domain plugins — relative order rarely matters
plugins.register(paywallPlugin)
plugins.register(parentalGatePlugin)
```

Undo first, persistence second, then domain plugins.

## Domain plugin wiring shape

Every domain plugin (Killswitch, ParentalGate, Paywall, or your own) takes the same three keypath/closure pieces:

```swift
SomePlugin(
    state: \.someFeature,                                         // WritableKeyPath into AppState
    action: AppAction.someFeature,                                // (FeatureAction) -> AppAction
    extractAction: { if case .someFeature(let a) = $0 { return a }; return nil },
    …                                                              // plugin-specific service / source / etc.
)
```

This is the contract — plugins never assume your root types.

## SwiftUI integration rules

- App owns the store with `@State`: `@State private var store = AppStore.configured()`. Inject via `.environment(store)`. Never recreate the store in `body`.
- Views read via `@Environment(AppStore.self)` and dispatch with `store.send(.someAction)`.
- For text fields and other controlled components, use a binding that reads `store.entityStore[id]?.name ?? ""` and dispatches `setName` on commit. Never let SwiftUI own the truth; the reducer does.
- Per-row observation: pass `store` (or a per-row binding into `EntityStore`) into a row view, and read inside that row. SwiftUI re-renders only what it reads.

## Conventions

- Re-export Swidux from `AppState.swift`: `@_exported import Swidux`. Other files don't need `import Swidux`.
- File layout: `App/AppState.swift`, `App/AppAction.swift`, `App/AppReducer.swift`, `App/AppStore.swift`, `App/AppEnvironment.swift`, `App/Effect.swift`. Features go in `Features/<Feature>Reducer.swift`. Models in `Models/`.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
- One reducer per feature; root reducer routes by case.
- Effects shouldn't capture mutable state. Capture services/closures from `environment`.

## When to use what

| Task | Tool |
|---|---|
| New struct field on AppState | Just add it; macro re-runs |
| New nested struct slice | `@SwiduxNested var slice: SliceState = .init()` |
| New mutation | New `AppAction` case + reducer arm |
| New async operation | Reducer returns an `Effect` that calls service and `await send(.someResult(…))` |
| Persist a new entity collection | Add `EntityStore<NewEntity>` to AppState, add `StateWriter(keyPath: \.newEntities) { … }` to PersistencePlugin |
| Persist a scalar preference (theme, last-seen version) | Inject `KeyValueStore` via `Environment`; hydrate at startup, write from an effect |
| Add undo for an action | Make `isUndoable` return `true` for that case |
| Block on app version | Wire `KillswitchPlugin` (see `swidux-patterns.md`) |
| Gate a feature on subscription | Wire `PaywallPlugin`; check `store.paywall.isGateSatisfied` |
| Gate an action on parent approval | Wire `ParentalGatePlugin`; dispatch `.parentalGate(.request(reason:))` |
| Custom cross-cutting feature | Write a `SwiduxPlugin` (see DocC `BuildingADomainPlugin`) |

## Anti-patterns

- ❌ Calling `await` or `try` inside a reducer
- ❌ Hand-writing an observer class when you could use `@SwiduxState`
- ❌ Calling `db.save()` or other I/O from inside a reducer
- ❌ Mutating state from inside an effect closure (effects dispatch actions, never mutate directly)
- ❌ Owning the store with `@StateObject` (use `@State` — `Store` is `@Observable`, not `ObservableObject`)
- ❌ Importing `Swidux` in every feature file (re-export from AppState.swift)
- ❌ Registering `PersistencePlugin` before `UndoPlugin` (snapshot must happen before any mutation)
- ❌ Using regular `var` for state slices that should be `@SwiduxNested` (loses per-property observation)
- ❌ Reading from `KeyValueStore` inside a reducer (reads are for hydration only — pull values into state at startup, then observe state)
- ❌ Touching `UserDefaults.standard` directly anywhere in app code (use `KeyValueStore` so tests can inject `InMemoryKeyValueStore`)

## Requirements

- Swift 6.2+ / Xcode 26+
- macOS 15+ / iOS 18+
- Strict concurrency (`.swiftLanguageMode(.v6)` is implicit at tools 6.2)

## Library targets

- `Swidux` — core (Store, plugins protocol, EntityStore, persistence, undo, macros)
- `SwiduxKillswitch` — version-blocking plugin
- `SwiduxParentalGate` — math-challenge gate plugin
- `SwiduxPaywall` — paywall + entitlement plugin (RevenueCat or StoreKit-shaped)
