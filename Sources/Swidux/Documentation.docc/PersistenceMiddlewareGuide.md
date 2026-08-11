# Persistence Middleware

Configure automatic persistence that drains entity changes and batches database writes.

## Overview

``PersistencePlugin`` is configured with one ``StateWriter`` per ``EntityStore``:

```swift
PersistencePlugin<AppState, AppAction>(
    writers: [
        StateWriter(keyPath: \.items) { writes, deletes in
            for item in writes { try await db.upsert(item) }
            for id in deletes  { try await db.delete(id: id) }
        },
    ],
    debounce: .milliseconds(250),  // Default; configurable
    retry: .default                // Default; configurable
)
```

> Important: Let the persist closure **throw**. The flush clears its buffers before the save runs, so an error you swallow with `try?` takes the write with it — the plugin never learns to put the batch back, and the value reaches storage only if the user happens to touch the same entity again. Throwing is what turns that into a retry. See ``RetryPolicy``.

When using ``Store``, `afterReduce` is called automatically through the plugin lifecycle — no manual invocation needed. Register the ``PersistencePlugin`` with ``PluginHost`` and pass it to ``Store``'s initializer.

Call `await store.flush()` on shutdown (`scenePhase == .background`, `applicationWillTerminate`) to ensure buffered writes aren't lost. This delegates to each registered plugin's `flush()` method.

## Writer Ordering

> Warning: **Writers flush sequentially in registration order.** If entity B references entity A via foreign key, A's writer **must** come first. Otherwise B's upsert looks up A's row before it exists.

Register leaf entities first, aggregates last. Include a defensive fallback in upsert methods — if a referenced entity isn't found, create it inline rather than setting the relationship to `nil`.

## Skip the boilerplate: `SwiduxPersistence`

The hand-wired form above (a `StateWriter` per `EntityStore`, plus a SwiftData
`@Model` shadow and a DB actor you write yourself) is the low-level path. The
**`SwiduxPersistence`** product turns it into a declare-and-register concern:
annotate a domain entity with `@Persisted` and the macro generates its `@Model`
shadow, the `init(from:)`/`toDomain()`/`update(from:)` converters, and a
`PersistableEntity` conformance. A generic `EntityDB` actor and a
`PersistenceCoordinator` build the container, synthesize the writers, and reuse
this `PersistencePlugin` under the hood — exposing only re-hydration paths that
merge, so a "refresh from disk" can't clobber unflushed writes or live edits.

**`SwiduxCloudKitSync`** layers opt-in iCloud sync on top: a runtime opt-out
toggle, launch-time entitlement/account detection, and a merge-based
remote-change observer. A tick narrows itself to the rows persistent history
says changed, so it costs O(k) rather than a full table scan; see
<doc:HowToAddICloudSync>. Linking it is the single signal that an app needs the
iCloud/CloudKit/Push entitlements.

