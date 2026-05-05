# Getting Started with Swidux

Add Swidux to your project and wire up unidirectional data flow with automatic persistence.

## Overview

This guide walks through the four steps to integrate Swidux: add the package, define your types, wire the store, and connect views.

## Add the Package

**Xcode:** File > Add Package Dependencies, paste `https://github.com/heirloomlogic/Swidux`, set **Up to Next Major** from `1.0.0`.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/heirloomlogic/Swidux", from: "1.0.0"),
]
```

## Define Your Types

Re-export Swidux from `AppState.swift` so no other file needs `import Swidux`:

```swift
// App/AppState.swift
import Foundation
@_exported import Swidux

@SwiduxState
struct AppState: Equatable, Sendable {
    var items = EntityStore<Item>()
    var tags  = EntityStore<Tag>()
    @SwiduxNested var ui = UIState()
}
```

`@SwiduxState` generates an `@Observable` companion class and `SwiduxObservable` conformance. `@SwiduxNested` marks nested state slices that get their own observer class for per-property observation granularity.

Specialize the generic effect system with your action type:

```swift
// App/Effect.swift
typealias Send = Swidux.Send<AppAction>
typealias Effect = Swidux.Effect<AppAction>
```

- ``Send`` is `@MainActor @Sendable (Action) -> Void` — dispatched actions hop back to the MainActor.
- ``Effect`` is a `@Sendable` async closure. Run with `Task { @concurrent in }` to stay off the MainActor.

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

Feature reducers conform to ``SwiduxReducer`` with `Action = FeatureAction` and `RootAction = AppAction`. Return `nil` when no async work is needed:

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

## Wire the Store

`Store` is a generic `@Observable` class that owns the dispatch cycle, plugin lifecycle, and observation layer. Define a typealias and a factory method:

```swift
typealias AppStore = Store<AppState, AppAction>

extension Store where State == AppState, Action == AppAction {
    static func configured() -> AppStore {
        let reducer = AppReducer()
        let environment = AppEnvironment.live()

        let persistencePlugin = PersistencePlugin<AppState, AppAction>(
            writers: [
                StateWriter(keyPath: \.items) { writes, deletes in
                    for item in writes { try? await db.upsert(item) }
                    for id in deletes  { try? await db.delete(id: id) }
                },
            ]
        )

        let plugins = PluginHost<AppState, AppAction>()
        plugins.register(persistencePlugin)

        return Store(
            initialState: AppState(),
            reducer: { state, action in
                reducer.reduce(state: &state, action: action, environment: environment)
            },
            plugins: plugins,
            persistencePlugin: persistencePlugin
        )
    }
}
```

`Store` handles the snapshot pattern internally — packing the observer tree into a struct, running the reducer, then unpacking only changed properties back. Views access state through `@dynamicMemberLookup`, which forwards to the generated observer class tree.

## Wire Views

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

### App Entry Point

Own the store with `@State` and inject it via `.environment()`:

```swift
@main
struct MyApp: App {
    @State private var store = AppStore.configured()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
```

## Next Steps

- <doc:EntityStoreGuide> — Learn the full ``EntityStore`` API
- <doc:PersistenceMiddlewareGuide> — Configure persistence writers
- <doc:ArchitectureGuide> — Understand the snapshot pattern and performance considerations
- `SwiduxObservable` — Hand-write observation bridging for advanced cases
