# Architecture & Performance

Understand the architectural patterns that make Swidux work correctly with SwiftUI's observation system.

## Overview

Swidux relies on specific patterns to ensure correct `@Observable` behavior, efficient rendering, and safe concurrency. This article explains the reasoning behind these patterns.

## The Snapshot Pattern

`Store.send()` copies the observer tree into a local struct, mutates the copy via the reducer, then assigns changed properties back. This happens internally via `SwiduxObservable` — `State(observer:)` packs, `State.apply(_:to:)` unpacks.

The pattern exists for two reasons:

1. **`@Observable` equality checking.** The `set` accessor checks `Equatable` and suppresses no-op notifications. Swift's `_modify` accessor (used by `inout`) fires notifications unconditionally. The snapshot pattern routes through `set`.

2. **Cross-slice observation isolation.** The `@Swidux` macro generates a separate `@Observable` class for each `@Slice` property. A view reading `store.items` won't re-render when only `store.ui` changes, because they live on different observer objects.

The `@Swidux` macro generates the observer class tree and `SwiduxObservable` conformance automatically. Hand-written conformance is still possible for advanced cases — see ``SwiduxObservable``.

> Note: Explicit equality guards (`if x != state.x { x = state.x }`) are unnecessary. `@Observable` already checks equality on `set`. Unconditional assignment is safe.

## Dispatch Loop Detection

``PersistencePlugin`` warns if more than 100 changes are drained within a single debounce interval (the `loopThreshold` parameter; 250 ms by default). It counts only dispatches that changed an ``EntityStore``, and it reports once per burst — the count starts over after a whole debounce interval with no drains. This usually means an effect or plugin dispatches an action on every state change, feeding the cycle it reacts to. A steady stream of edits, such as a slider drag, stays well under the threshold and is not reported.

## Debounced Persistence

Each drain restarts the flush's debounce timer, so a burst of edits is written once. The timer is never pushed further than `maxWait` past the oldest pending change (four debounce intervals, and at least a second, by default), so continuous edits still reach storage while they continue. A retry of a failed flush keeps its own schedule; a new edit postpones it only when the flush it schedules is due first and carries the failed batch anyway.

## Reducer Weight

Reducers run synchronously on the MainActor. Move O(n²) work into an ``Effect`` and dispatch the result back as an action.

## Effect Threading

> Important: Effects run on Swift concurrency's cooperative thread pool via `Task { @concurrent in }`. Blocking calls (`Process.waitUntilExit()`, `DispatchSemaphore.wait()`, `Thread.sleep()`) hold threads hostage. If enough block, the pool starves and the MainActor freezes.

Use async alternatives: `terminationHandler` + continuation instead of `waitUntilExit()`, `Task.sleep()` instead of `Thread.sleep()`, async file I/O instead of `Data(contentsOf:)`.
