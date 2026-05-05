# Architecture & Performance

Understand the architectural patterns that make Swidux work correctly with SwiftUI's observation system.

## Overview

Swidux relies on specific patterns to ensure correct `@Observable` behavior, efficient rendering, and safe concurrency. This article explains the reasoning behind these patterns.

## The Snapshot Pattern

`Store.send()` copies the observer tree into a local struct, mutates the copy via the reducer, then assigns changed properties back. This happens internally via `SwiduxObservable` — `State(observer:)` packs, `State.apply(_:to:)` unpacks.

The pattern exists for two reasons:

1. **`@Observable` equality checking.** The `set` accessor checks `Equatable` and suppresses no-op notifications. Swift's `_modify` accessor (used by `inout`) fires notifications unconditionally. The snapshot pattern routes through `set`.

2. **Cross-slice observation isolation.** The `@SwiduxState` macro generates a separate `@Observable` class for each `@SwiduxNested` property. A view reading `store.items` won't re-render when only `store.ui` changes, because they live on different observer objects.

The `@SwiduxState` macro generates the observer class tree and `SwiduxObservable` conformance automatically. Hand-written conformance is still possible for advanced cases — see ``SwiduxObservable``.

> Note: Explicit equality guards (`if x != state.x { x = state.x }`) are unnecessary. `@Observable` already checks equality on `set`. Unconditional assignment is safe.

## Dispatch Loop Detection

``PersistencePlugin`` warns if `afterReduce` is called more than 100 times per debounce interval. This usually means `send()` isn't using the snapshot pattern, causing cascading re-renders that trigger re-dispatches.

## Reducer Weight

Reducers run synchronously on the MainActor. Move O(n²) work into an ``Effect`` and dispatch the result back as an action.

## Effect Threading

> Important: Effects run on Swift concurrency's cooperative thread pool via `Task { @concurrent in }`. Blocking calls (`Process.waitUntilExit()`, `DispatchSemaphore.wait()`, `Thread.sleep()`) hold threads hostage. If enough block, the pool starves and the MainActor freezes.

Use async alternatives: `terminationHandler` + continuation instead of `waitUntilExit()`, `Task.sleep()` instead of `Thread.sleep()`, async file I/O instead of `Data(contentsOf:)`.
