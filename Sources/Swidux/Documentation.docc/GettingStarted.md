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

## Wire the AppStore

`AppStore` owns separate stored properties per state slice so `@Observable` tracks each one independently. `send()` uses the snapshot pattern (see <doc:ArchitectureGuide#The-Snapshot-Pattern>):

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

## Next Steps

- <doc:EntityStoreGuide> — Learn the full ``EntityStore`` API
- <doc:PersistenceMiddlewareGuide> — Configure persistence writers
- <doc:ArchitectureGuide> — Understand the snapshot pattern and performance considerations
