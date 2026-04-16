# Swidux

**Redux-style state management for SwiftUI + SwiftData.**

Swidux is a persistence middleware layer for apps that use unidirectional data flow. Reducers mutate state, and the middleware detects what changed and persists it. You don't write save calls, load/loaded action pairs, or persistence code in features.

## Features

- **EntityStore** — Ordered, keyed collection with built-in change tracking
- **PersistenceMiddleware** — Debounced orchestrator that coalesces and batches DB writes
- **UndoMiddleware** — Opt-in stack-based undo/redo for state snapshots
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
@Observable
final class AppStore: SwiduxDispatcher {
    private(set) var items = EntityStore<Item>()

    private let reducer = AppReducer()
    private let persistence: PersistenceMiddleware<AppState>

    func send(_ action: AppAction) {
        var state = AppState(items: items)
        let effect = reducer.reduce(state: &state, action: action, environment: env)
        persistence.afterReduce(state: &state)
        items = state.items

        if let effect {
            let send: Send = { [weak self] action in self?.send(action) }
            Task { @concurrent in await effect(send) }
        }
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

Swidux includes an agent skill at `skills/swidux-ref/` for AI coding assistants like [Claude Code](https://claude.ai/claude-code). It contains the architecture rules, conventions, and code templates the assistant needs to generate correct Swidux code. Copy the skill directory into your downstream project to activate it. See the [Agent Skill](https://heirloomlogic.github.io/Swidux/documentation/swidux/agentskill) article for setup details.

## Requirements

Swift 6.2+ / Xcode 26+, macOS 15+ / iOS 18+. Strict concurrency (`.swiftLanguageMode(.v6)`).

## License

See [LICENSE](LICENSE) for details.
