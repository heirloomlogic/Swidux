# Swidux

**Redux-style state management for SwiftUI + SwiftData.**

Swidux is a persistence middleware layer for apps that use unidirectional data flow. Reducers mutate state, and the middleware detects what changed and persists it. You don't write save calls, load/loaded action pairs, or persistence code in features.

## Features

- **Store** — Generic `@Observable` store with `@dynamicMemberLookup`, dispatch cycle, undo/redo, and plugin lifecycle
- **@SwiduxState / @SwiduxNested** — Macros that auto-generate `@Observable` observer classes from state structs
- **SwiduxObservable** — Protocol bridging value-type state to `@Observable` class trees
- **EntityStore** — Ordered, keyed collection with built-in change tracking
- **PersistencePlugin** — Debounced orchestrator that coalesces and batches DB writes
- **UndoPlugin** — Opt-in stack-based undo/redo for state snapshots
- **SwiduxPlugin / PluginHost** — Unified extension point and ordered registry for the dispatch cycle
- **Effect / Send** — Generic typealiases for the async effect system
- **SwiduxReducer / SwiduxDispatcher** — Protocols enforcing the reducer and dispatch contracts

## Installation

**Xcode:** File > Add Package Dependencies, paste `https://github.com/heirloomlogic/Swidux`, set **Up to Next Major** from `1.0.0`.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/heirloomlogic/Swidux", from: "1.0.0"),
]
```

## Quick Start

```swift
@SwiduxState
struct AppState: Equatable, Sendable {
    var items = EntityStore<Item>()
    @SwiduxNested var ui = UIState()
}

typealias AppStore = Store<AppState, AppAction>

extension Store where State == AppState, Action == AppAction {
    static func configured() -> AppStore {
        let plugins = PluginHost<AppState, AppAction>()
        plugins.register(persistencePlugin)
        return Store(
            initialState: AppState(),
            reducer: { state, action in
                AppReducer().reduce(state: &state, action: action, environment: .live())
            },
            plugins: plugins,
            persistencePlugin: persistencePlugin
        )
    }
}
```

Views dispatch actions and read from the store. They never import Swidux or touch the database.

## Documentation

Full documentation is available as [DocC articles](https://heirloomlogic.github.io/Swidux/documentation/swidux/) covering:

- [Getting Started](https://heirloomlogic.github.io/Swidux/documentation/swidux/gettingstarted) — Installation, types, wiring
- [EntityStore](https://heirloomlogic.github.io/Swidux/documentation/swidux/entitystore) — Collection API, merging, restore
- [Persistence Middleware](https://heirloomlogic.github.io/Swidux/documentation/swidux/persistencemiddleware) — Writers, flushing, ordering
- [Undo / Redo](https://heirloomlogic.github.io/Swidux/documentation/swidux/undoredo) — Snapshots, coalescing, platform wiring
- [Architecture](https://heirloomlogic.github.io/Swidux/documentation/swidux/architecture) — Snapshot pattern, performance
- [Design Principles](https://heirloomlogic.github.io/Swidux/documentation/swidux/designprinciples) — Philosophy

## Agent Skill

Swidux provides a companion agent skill (`swidux-ref`) for AI coding assistants like [Claude Code](https://claude.ai/claude-code). The skill contains architecture rules, conventions, and code templates for generating correct Swidux code. It is auto-discovered by Claude Code in projects that depend on Swidux. See the [Agent Skill](https://heirloomlogic.github.io/Swidux/documentation/swidux/agentskill) article for details.

## Requirements

Swift 6.2+ / Xcode 26+, macOS 15+ / iOS 18+. Strict concurrency (`.swiftLanguageMode(.v6)`).

## License

See [LICENSE](LICENSE) for details.
