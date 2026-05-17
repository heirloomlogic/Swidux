# Plugin Architecture

Extend the dispatch cycle with lifecycle hooks — from invisible infrastructure to domain-specific features.

## Overview

Swidux's plugin system is a single protocol (``SwiduxPlugin``) with four lifecycle hooks and an ordered registry (``PluginHost``). All store extensibility flows through this contract. The built-in ``PersistencePlugin`` and ``UndoPlugin`` use it, and so do domain-specific features like killswitch enforcement and paywall management.

## The Dispatch Lifecycle

Every call to `store.send()` drives plugins through a four-phase lifecycle:

```
plugins.willReduce(state:action:)      // 1. Pre-reduce (read-only state)
appReducer.reduce(state:action:...)    // 2. App reducer runs
pluginEffects = plugins.reduce(...)    // 3. Plugin reducers run
plugins.afterReduce(state:action:)     // 4. Post-reduce cleanup
```

The generic ``Store`` implements this lifecycle internally. You don't write `send()` by hand — `Store.send()` handles packing, reducing, plugin hooks, unpacking, and effect dispatch.

A fifth method, `flush()`, runs once at shutdown to drain async buffers.

All four hooks have default no-op implementations. Each plugin overrides only what it needs.

## Core Middleware vs Domain Plugins

The plugin system serves two structurally different roles. Recognizing which one a plugin fills determines where it lives, which hooks it uses, and how it couples to the host app.

### Core Middleware

``PersistencePlugin`` and ``UndoPlugin`` are **action-agnostic infrastructure**. They never inspect the `Action` type, never dispatch actions, and never return effects. They couple only to the shape of state:

- ``PersistencePlugin`` needs keypaths to ``EntityStore`` properties.
- ``UndoPlugin`` needs `State: Equatable` so it can snapshot and compare.

Because they don't touch actions, they work with any app that uses Swidux — no wiring required beyond construction.

### Domain Plugins

Killswitch, parental gate, and paywall plugins are **domain-specific modules** that ship as separate library targets (`SwiduxKillswitch`, `SwiduxParentalGate`, `SwiduxPaywall`). They own their own state slices and action enums, dispatch effects, and must be explicitly wired into the host app's root types.

Each domain plugin stores three wiring pieces:

```swift
private let stateKeyPath: WritableKeyPath<RootState, FeatureState>
private let toRootAction: @Sendable (FeatureAction) -> RootAction
private let extractAction: @Sendable (RootAction) -> FeatureAction?
```

The host app provides these at init — the plugin never assumes a specific root type.

### Comparison

| | Core Middleware | Domain Plugins |
|---|---|---|
| **Action knowledge** | None | Full — extracts and lifts actions |
| **Lifecycle hooks** | `willReduce` or `afterReduce` | `reduce` only |
| **Returns effects** | No | Yes |
| **State coupling** | Keypath to ``EntityStore`` or `Equatable` constraint | Keypath to plugin's own state slice |
| **Wiring** | Construction only | Keypath + action lifter + action extractor |
| **Target** | Core `Swidux` library | Separate library target |
| **Opt-in** | Instantiate and register | Add state, action case, and register |

## The Decision Rule

> Important: Does the middleware need to know your action type? If **no**, it's core middleware — put it in `Swidux` and use `willReduce` or `afterReduce`. If **yes**, it's a domain plugin — give it its own target and use `reduce`.

## Hook Selection Guide

- **`willReduce(state:action:)`** — Capture state *before* the reducer mutates it. State is read-only. Use for snapshots (undo) or pre-mutation analytics.
- **`reduce(state:action:) -> Effect?`** — Handle domain-specific actions *after* the app reducer. Mutate the plugin's state slice and return effects. This is the only hook that can dispatch actions or do async work.
- **`afterReduce(state:action:)`** — Observe state *after* all reducing is done. Use for persistence draining, logging, or metrics. Cannot return effects.
- **`flush() async`** — Shutdown hook. Flush pending async buffers (persistence writes, analytics batches). Called once when the app exits.

## Registration Order

``PluginHost`` executes plugins in registration order. Recommended ordering:

```swift
let plugins = PluginHost<AppState, AppAction>()
plugins.register(undoPlugin)         // 1. Must snapshot before any mutation
plugins.register(persistencePlugin)  // 2. Drains changelogs after reducer
plugins.register(killswitchPlugin)   // 3. Domain plugins in any order
plugins.register(paywallPlugin)
```

Undo must come first — it snapshots state in `willReduce`, before the app reducer or any plugin modifies it. Persistence typically comes next so its `afterReduce` drain sees the final state. Domain plugins use only `reduce`, so their relative order rarely matters.

## Service-result actions and transition observation

A *service-result action* — `PaywallPlugin`'s `customerInfoUpdated`,
`KillswitchPlugin`'s `verdictReceived`, `FeatureFlagsPlugin`'s
`refreshSucceeded` — fires on **every** fetch, refresh, or stream tick, not
only when the value changed, and unconditionally writes its payload to the
state slice. The payload is frequently identical to what is already there
(a re-delivered entitlement, an unchanged remote config).

Do **not** map analytics or side effects to the raw service-result action:
it fires duplicates by design. Observe the **state slice** — or a value
derived from it — instead.

State observation is already deduplicated by the framework. `Store.send`
packs the observer into a value-type snapshot, lets reducers mutate the
snapshot, then writes back via `State.apply`. For a leaf slice that write
is a plain assignment whose `@Observable` setter equality-gates `Equatable`
values, so a slice whose value did not change emits no notification — and a
value-diffing consumer such as `AnalyticsIdentity.userProperties` (which
`AnalyticsPlugin` re-evaluates and diffs every dispatch) sees exactly the
real transitions. This dedup is a property of the `Store`, not of any
per-plugin guard, so a no-op service-result cycle is silent to state
observers without any extra reducer logic.

## Next Steps

- <doc:BuildingADomainPlugin> — Step-by-step guide to creating a domain plugin
- <doc:PersistenceMiddlewareGuide> — Configure the built-in persistence middleware
- <doc:UndoRedo> — Add undo/redo with the built-in undo middleware
