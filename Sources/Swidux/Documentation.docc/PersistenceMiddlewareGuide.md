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

When using ``Store``, `afterReduce` is called automatically through the plugin lifecycle — no manual invocation needed. Register the ``PersistencePlugin`` with ``PluginHost`` and pass it to ``Store``'s initializer.

Call `await store.flush()` on shutdown (`scenePhase == .background`, `applicationWillTerminate`) to ensure buffered writes aren't lost. This delegates to each registered plugin's `flush()` method.

## Writer Ordering

> Warning: **Writers flush sequentially in registration order.** If entity B references entity A via foreign key, A's writer **must** come first. Otherwise B's upsert looks up A's row before it exists.

Register leaf entities first, aggregates last. Include a defensive fallback in upsert methods — if a referenced entity isn't found, create it inline rather than setting the relationship to `nil`.
