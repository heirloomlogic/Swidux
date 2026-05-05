# Persistence Middleware

Configure automatic persistence that drains entity changes and batches database writes.

## Overview

``PersistencePlugin`` is configured with one ``StateWriter`` per ``EntityStore``:

```swift
PersistencePlugin<AppState, AppAction>(
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

## Writer Ordering

> Warning: **Writers flush sequentially in registration order.** If entity B references entity A via foreign key, A's writer **must** come first. Otherwise B's upsert looks up A's row before it exists.

Register leaf entities first, aggregates last. Include a defensive fallback in upsert methods — if a referenced entity isn't found, create it inline rather than setting the relationship to `nil`.
