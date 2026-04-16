# ``Swidux``

Redux-style state management for SwiftUI with built-in persistence.

@Metadata {
    @DisplayName("Swidux")
}

## Overview

Swidux is a persistence middleware layer for apps that use unidirectional data flow. Reducers mutate state, and the middleware detects what changed and persists it. You don't write save calls, load/loaded action pairs, or persistence code in features.

```
View → store.send(.action)
  → Reducer mutates state (EntityStore tracks changes silently)
  → PersistenceMiddleware drains changelogs from EntityStores
  → StateWriters accumulate pending writes
  → Debounce timer fires → batched DB writes execute
  → View re-renders via @Observable
```

### Features

- **``EntityStore``** — Ordered, keyed collection with built-in change tracking
- **``ChangeSet``** — Tracks which entity IDs were upserted or deleted
- **``StateWriter``** — Drains changelogs and accumulates batched persistence work
- **``PersistenceMiddleware``** — Debounced orchestrator that flushes writes after each reducer call
- **``UndoMiddleware``** — Opt-in stack-based undo/redo for state snapshots
- **``Effect`` / ``Send``** — Generic typealiases for the async effect system
- **``SwiduxReducer``** — Protocol enforcing the reducer contract
- **``SwiduxDispatcher``** — Protocol enforcing the store dispatch contract

Your state, actions, domain models, and DB actors live in your app. Swidux provides the contracts and persistence plumbing.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:DesignPrinciples>

### Data

- ``EntityStore``
- ``ChangeSet``

### Persistence

- <doc:PersistenceMiddlewareGuide>
- ``PersistenceMiddleware``
- ``StateWriter``

### Undo / Redo

- <doc:UndoRedo>
- ``UndoMiddleware``

### Architecture

- <doc:ArchitectureGuide>

### Protocols & Effects

- ``SwiduxReducer``
- ``SwiduxDispatcher``
- ``Effect``
- ``Send``

### Tools

- <doc:AgentSkill>
