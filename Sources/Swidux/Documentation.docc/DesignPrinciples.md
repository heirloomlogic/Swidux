# Design Principles

The 10 rules that shape every Swidux app, and the reasoning behind them.

## Overview

Swidux's surface area looks small — a `Store`, a reducer protocol, a plugin protocol — but the API is opinionated. These principles explain *why* the API has the shape it does, so you can extend it correctly.

## 1. State is a value, observation is a class

State is a struct. Mutations go through `inout State`, which is predictable, snapshottable, and testable. SwiftUI observation needs an `@Observable` reference type. Reconciling these two requires a class that mirrors the struct.

`@Swidux` generates that class for you (`<StructName>Observer`) and wires up the `SwiduxObservable` conformance that bridges the two. Don't hand-write the observer. The `pack → reduce → unpack-diff → observe` cycle is what gives you per-property re-renders without coupling reducers to a class.

`@Slice` extends this to nested struct slices: each slice gets its own observer class so observation stays granular even across composition.

## 2. Reducers are pure and synchronous

Reducers take `inout State` and an `Action`, mutate state in place, and return an optional ``Effect``. They never `await`, never `throw`, and never call I/O directly.

Why: pure synchronous mutations are trivially testable, deterministic, and snapshot-friendly. When you need async work (network, disk, timers), return an `Effect` containing a `@Sendable` async operation that runs off the MainActor and dispatches follow-up actions back through `send`.

## 3. Effects run off MainActor; sends hop back

``Effect`` is a `Sendable` value containing an async throwing operation and cancellation metadata. Construct it with `Effect { send in ... }`; use `map` to lift its actions without losing metadata. The `Store` runs effects in `Task { @concurrent in }` so they don't block UI. ``Send`` is `@MainActor @Sendable (Action) -> Void`, so dispatching from inside an effect always lands back on MainActor — no manual hops, no race conditions on state.

The split is deliberate: effects own the work, the reducer owns the state.

## 4. Persistence is invisible

Reducers mutate ``EntityStore`` properties; ``EntityStore`` records every change in a ``ChangeSet``; ``PersistencePlugin`` debounces and drains those changesets through ``StateWriter`` closures.

You never write `db.save()` in a feature. A reducer that adds an item is identical whether the entity is persisted to SwiftData, SQLite, or nowhere — register or don't register a writer. This is the principle that makes Swidux apps feel small: persistence stops being a concern of feature code.

## 5. Synchronous state, async persistence

State updates synchronously inside the reducer for instant UI feedback. Persistence happens asynchronously: ``EntityStore`` change tracking is in-memory and free; the debounced persistence flush coalesces rapid mutations into a single batched write.

Tap-tap-tap-tap on an increment button updates the UI on every tap and produces one DB write a moment later. Reducers stay synchronous; storage stays cheap.

## 6. Plugins are the single extension point

Everything that hangs off the dispatch cycle is a ``SwiduxPlugin``. Persistence, undo, killswitch, parental gate, paywall — same protocol, same lifecycle hooks. You can add your own without forking Swidux.

Two structural patterns:

- **Core middleware** (``PersistencePlugin``, ``UndoPlugin``) — action-agnostic. Doesn't know your action type. Couples only to state shape (`Equatable` for undo; ``EntityStore`` keypaths for persistence).
- **Domain plugins** (`KillswitchPlugin`, `ParentalGatePlugin`, `PaywallPlugin`, your own) — owns a state slice and an action enum. Wires into your root types via keypath + action lifter + extractor.

The decision rule: *does this need to know your action type?* If no, write core middleware and use `willReduce` or `afterReduce`. If yes, write a domain plugin and use `reduce`.

## 7. Bind to the store, not to `@State`

Form inputs read from the store and dispatch on write. Use ``Store/binding(_:sending:)`` for the common case (read one property, dispatch one action), and fall back to `Binding(get:set:)` when the read is a transformation (optional unwraps, derived values) or the setter wraps the dispatch in animation or branching. Don't buffer mutable form state in `@State` and write back on a button.

Why: every mutation flows through the reducer, which means undo/redo, persistence, and any plugin that watches the dispatch cycle sees every keystroke (subject to coalescing). If you stash state in `@State`, those plugins are blind to it.

The trade-off is more dispatches per keystroke. Coalescing — see ``UndoPlugin`` — collapses bursts of the same action into a single undo step.

## 8. Registration order matters at the boundaries

``UndoPlugin`` snapshots in `willReduce`, so it must run *before* any plugin or reducer mutates state — register it first. ``PersistencePlugin`` drains changelogs in `afterReduce`, so it wants the post-mutation state — register it after undo. Domain plugins use only `reduce`, so their relative order rarely matters.

The recommended order:

```swift
plugins.register(undoPlugin)         // 1. snapshots first
plugins.register(persistencePlugin)  // 2. drains after reducer
plugins.register(killswitchPlugin)   // 3. domain plugins
plugins.register(paywallPlugin)
plugins.register(parentalGatePlugin)
```

## 9. Strict concurrency, on purpose

Swidux is built for `swiftLanguageMode(.v6)` and assumes Swift 6 strict concurrency throughout. State must be `Sendable`. The macros mark generated code carefully. Effects use explicit isolation (`@Sendable`, `@MainActor`, `@concurrent`).

This is friction at first — you'll get warnings about `Sendable` types. Honour them. The result is a state-management layer that composes safely with `async/await` and SwiftData without the surprise data races you get from pre-Swift 6 designs.

## 10. The store is opinionated; your app is not

Swidux gives you a `Store`, a reducer protocol, a plugin protocol, and three optional plugins. It does not give you:

- A dependency-injection container (write your own `AppEnvironment`).
- A navigation library (use SwiftUI navigation).
- A network layer (use `URLSession`, structured concurrency, or whatever you want).
- An opinion on database (SwiftData, GRDB, SQLite, Core Data — register a `StateWriter` and Swidux doesn't care).

The store owns one job: take an action, produce a new state, run effects. Everything else is yours.

## 11. Service shapes: protocol when others implement it, closures when we own it

Swidux services deliberately come in two shapes, chosen by who supplies the implementation:

- **Protocol** — when apps or vendor adapters implement the backend:
  `PaywallService` (RevenueCat, StoreKit, simulated), `AnalyticsService`
  (Mixpanel, Amplitude, console), `FeatureFlagsService` (any JSON host).
  A protocol gives conformers a stable, documented contract.
- **Struct of closures** — when the library owns the shape and apps only
  configure or mock it: `KillswitchService`, `ParentalChallengeSource`,
  `SyncPreflightService`. Closures make the built-in `.live`/`.mock`
  factories and per-test overrides trivial without a conformance ceremony.

The split is a signal, not an accident: if you find yourself conforming to a
struct-of-closures service, that service was designed to be configured, not
replaced.

## Anti-patterns

- ❌ `await` or `try` inside a reducer — return an effect instead.
- ❌ Hand-writing the observer class when you could use `@Swidux`.
- ❌ Calling `db.save()` from inside a reducer — use ``StateWriter``.
- ❌ Mutating state from inside an effect — effects dispatch actions; the reducer mutates.
- ❌ Owning the store with `@StateObject` — use `@State` (`Store` is `@Observable`, not `ObservableObject`).
- ❌ Buffering form state in `@State` and committing on submit — bind to the store directly.
- ❌ Registering ``PersistencePlugin`` before ``UndoPlugin`` — snapshot must precede mutation.

## See Also

- <doc:ArchitectureGuide>
- <doc:PluginArchitecture>
- <doc:BuildingYourFirstApp>
