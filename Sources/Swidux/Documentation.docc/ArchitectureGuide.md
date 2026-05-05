# Architecture & Performance

Understand the architectural patterns that make Swidux work correctly with SwiftUI's observation system.

## Overview

Swidux relies on specific patterns to ensure correct `@Observable` behavior, efficient rendering, and safe concurrency. This article explains the reasoning behind these patterns.

## The Snapshot Pattern

`send()` copies stored properties into a local `AppState`, mutates the copy via the reducer, then assigns back. This is required for two reasons:

1. **`@Observable` equality checking.** The `set` accessor checks `Equatable` and suppresses no-op notifications. Swift's `_modify` accessor (used by `inout`) fires notifications unconditionally. The snapshot pattern routes through `set`.

2. **Cross-slice observation isolation.** Separate stored properties (`var items`, `var tags`, `var ui`) mean a view reading `store.items` won't re-render when only `store.ui` changes. A single `var state: AppState` would invalidate all observers on every dispatch.

Because the stored properties are app-specific, `send()` cannot be provided by the framework — it must be written in each app's `AppStore`.

> Note: Explicit equality guards (`if x != state.x { x = state.x }`) are unnecessary. `@Observable` already checks equality on `set`. Unconditional assignment is safe.

## Dispatch Loop Detection

``PersistencePlugin`` warns if `afterReduce` is called more than 100 times per debounce interval. This usually means `send()` isn't using the snapshot pattern, causing cascading re-renders that trigger re-dispatches.

## Reducer Weight

Reducers run synchronously on the MainActor. Move O(n²) work into an ``Effect`` and dispatch the result back as an action.

## Effect Threading

> Important: Effects run on Swift concurrency's cooperative thread pool via `Task { @concurrent in }`. Blocking calls (`Process.waitUntilExit()`, `DispatchSemaphore.wait()`, `Thread.sleep()`) hold threads hostage. If enough block, the pool starves and the MainActor freezes.

Use async alternatives: `terminationHandler` + continuation instead of `waitUntilExit()`, `Task.sleep()` instead of `Thread.sleep()`, async file I/O instead of `Data(contentsOf:)`.
