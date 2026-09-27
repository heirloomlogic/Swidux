# Undo / Redo

Add stack-based undo/redo to your app with ``UndoPlugin``.

## Overview

``UndoPlugin`` captures state snapshots before each undoable action. Undo history lives in memory (lost on relaunch), but restored state is persisted normally via ``EntityStore``'s `restore(from:)`.

If you don't use ``UndoPlugin``, nothing changes. It's fully opt-in.

## Adding Undo to Your App

### 1. Create the plugin

Pass declarative predicates to classify which actions are undoable and which coalesce:

```swift
let isUndoable: @Sendable (AppAction) -> Bool = { action in
    switch action {
    case .items(.create), .items(.delete), .items(.rename): true
    case .selectItem, .toggleSidebar: false
    }
}

let undoPlugin = UndoPlugin<AppState, AppAction>(
    isUndoable: isUndoable,
    coalescing: { action in
        if case .items(.rename) = action { return true }
        return false
    }
)
```

### 2. Register it

Register the plugin with ``PluginHost``, first, so it snapshots before anything else touches state. ``Store`` finds it there — as it finds a registered ``PersistencePlugin`` — so registering once is enough:

```swift
let plugins = PluginHost<AppState, AppAction>()
plugins.register(undoPlugin)
plugins.register(persistencePlugin)

return Store(
    initialState: AppState(),
    reducer: { state, action in
        reducer.reduce(state: &state, action: action, environment: environment)
    },
    plugins: plugins
)
```

`Store` handles the rest internally: snapshotting state before undoable actions, restoring via `applyRestore` on undo/redo, draining persistence changes, updating `canUndo`/`canRedo`, and registering each undo step with the platform `UndoManager`. The `undoPlugin:` and `persistencePlugin:` initializer parameters still exist, for driving a plugin that isn't registered, but the defaults follow the registered plugins.

The Edit menu offers exactly the steps the plugin snapshotted, in the same order, so the two can't disagree about which step is next. `Store`'s old `isUndoable:` parameter, which filtered platform registration separately, is deprecated and ignored: a filter narrower than the plugin's predicate made an Edit ▸ Undo step revert whichever snapshot was newest rather than the one it offered. Put the predicate on `UndoPlugin(isUndoable:)`.

### 3. Wire platform UI

**macOS** — replace the Edit menu:

```swift
WindowGroup { ... }
.commands {
    CommandGroup(replacing: .undoRedo) {
        Button("Undo") { store.undo() }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!store.canUndo)
        Button("Redo") { store.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!store.canRedo)
    }
}
```

**iOS** — bridge the system UndoManager for shake-to-undo:

```swift
// In your view — connect the environment UndoManager:
.onAppear { store.undoManager = undoManager }
.onChange(of: undoManager) { _, new in store.undoManager = new }
```

`Store` registers one step with the `UndoManager` for each undo snapshot, so a coalesced run of keystrokes is one step in the Edit menu too.

Once an `UndoManager` is attached, calling ``Store/undo()`` or ``Store/redo()`` directly — from an in-app button, or from the macOS `CommandGroup` above — routes through it. The Edit menu, shake-to-undo, and your own buttons then walk one history, and each can undo or redo what another did. If the manager holds none of the store's steps (it was attached after the edits were made), the store steps its own history instead and leaves the manager alone.

That history is the manager's, not the store's alone. A window's manager is shared — text fields register their typing on it, and so can a SwiftData `ModelContext` — so when another client's step is the most recent one, the in-app button undoes *that*, exactly as Edit ▸ Undo would, and the store is left as it is until the next press. `store.canUndo` describes only the store's own steps; to enable a button that matches the Edit menu, read the manager's `canUndo`. For a store-only history, give the store an `UndoManager` of its own rather than the window's — at the cost of the Edit menu and shake-to-undo, which use the window's.

A store may be shorter-lived than the window's manager — a per-sheet or per-document store, or one rebuilt on account switch. When it is deallocated it takes its steps off the manager, and any step left behind (the manager was swapped out first) does nothing when invoked.

## Coalescing

The `coalescing` predicate groups consecutive matching actions into a single undo step. The first coalescing action captures a snapshot; subsequent consecutive coalescing actions share that snapshot. A non-coalescing action or undo/redo resets the flag. Typing "hello" produces one undo entry, not five.

"Non-coalescing" includes actions that aren't undoable. With the predicates above, renaming item A, selecting item B, then renaming item B is two undo steps: `.selectItem` isn't undoable, but it still ends the run, so one undo can't revert both renames.

That also means an action dispatched *between* keystrokes splits the run — for example an effect that sends `.nameValidated` after every `.rename`. If such an action should pass through a run without ending it, match it in the `coalescing` predicate as well. For an action that isn't undoable, that has no effect beyond keeping the run open.

## What undo restores

Two separate decisions govern undo. `isUndoable` decides *when* a snapshot is taken. ``SwiduxObservable/restoresOnUndo`` decides *what* is restored from it.

A snapshot is the whole root state, so restoring it reverts every change made since, including changes from actions you classified as non-undoable. In the example above, undoing a rename also reverts a later `.selectItem`. Keep state that must survive an undo in a type that opts out.

A type opts out by returning `false`:

```swift
@Swidux
nonisolated struct SessionState: Equatable, Sendable {
    static var restoresOnUndo: Bool { false }

    var lastSyncedAt: Date? = nil
}
```

A parent's generated `applyRestore` then keeps the current value of every property of that type, through undo and redo alike. This holds whether the property is marked `@Slice` or held as a plain value, and when it is held as an optional (`SessionState?`) or an array (`[SessionState]`). Other containers, such as a dictionary of state, are restored from the snapshot as a whole.

Plugin-owned slices are never restored. `KillswitchState`, `AnalyticsState`, `ParentalGateState`, `FeatureFlagsState`, `PaywallState` and `PersistenceState` all opt out. Their values mirror something outside the state, such as a server verdict, a consent decision, a cooldown or an in-flight request, and only the plugin's own reducer keeps the two in step. Restoring them from a snapshot would lift a killswitch block, reverse an analytics opt-out without running the consent hook, hand back a revoked parental-gate pass, or latch a flag refresh that no request is left to clear.

## Undo and sync

Undo is scoped to changes the local user made. If another device deletes an entity and the merge surfaces that mid-session, `restore(from:)` will not bring the row back, even though older undo snapshots still contain it.

That has to be the rule, because the alternative is worse than a missing undo step: restoring the row records it as a **creation**, which syncs out and re-seeds every peer that had already agreed it was gone. One person's undo would undo everybody's delete.

``EntityStore`` tracks this in `remotelyRemovedIDs`. An ID leaves the set the moment it becomes local again — the user creates it, or the row reappears on disk because the other device undid *its* delete — so nothing is permanently un-undoable. See <doc:EntityStoreGuide> for the mechanics.

The same holds in the other direction. If another device creates an entity and the merge surfaces it after an undo snapshot was taken, undoing past that snapshot keeps the row instead of deleting it — a deletion would sync out and remove the other device's creation everywhere. Redo follows the same rule. The row is still the local user's to edit and delete, and undo and redo of *those* changes work as usual.

Hydration counts as arriving from storage too. If an action is dispatched before `PersistenceCoordinator.hydrate(into:)` finishes loading a live store — an `.onAppear`, a restored search field — its snapshot holds the still-empty store, and undoing it keeps every hydrated row rather than deleting them all from disk. A hand-written hydration that replaces a live ``EntityStore`` should build it with `EntityStore(hydrating:)` for the same reason.

Apps that don't sync still get the hydration rule; beyond that nothing is recorded, and undo behaves exactly as it always has.

## Memory

Each snapshot is a value-type copy of your state. Cost is proportional to the number of entities across all stores. Use `maxDepth` to bound memory for large state:

```swift
let undoPlugin = UndoPlugin<AppState, AppAction>(maxDepth: 50, ...)
```
