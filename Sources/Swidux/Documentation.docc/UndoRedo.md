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

### 2. Register and pass to Store

Register the plugin with ``PluginHost`` for lifecycle hooks, and pass it directly to ``Store`` for undo/redo methods and `canUndo`/`canRedo` tracking:

```swift
let plugins = PluginHost<AppState, AppAction>()
plugins.register(undoPlugin)
plugins.register(persistencePlugin)

return Store(
    initialState: AppState(),
    reducer: { state, action in
        reducer.reduce(state: &state, action: action, environment: environment)
    },
    plugins: plugins,
    undoPlugin: undoPlugin,
    persistencePlugin: persistencePlugin,
    isUndoable: isUndoable
)
```

`Store` handles the rest internally: snapshotting state before undoable actions, restoring via `applyRestore` on undo/redo, draining persistence changes, and updating `canUndo`/`canRedo`.

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

`Store` automatically registers undo/redo actions with the `UndoManager` after each undoable dispatch.

## Coalescing

The `coalescing` predicate groups consecutive matching actions into a single undo step. The first coalescing action captures a snapshot; subsequent consecutive coalescing actions share that snapshot. A non-coalescing action or undo/redo resets the flag. Typing "hello" produces one undo entry, not five.

## Memory

Each snapshot is a value-type copy of your state. Cost is proportional to the number of entities across all stores. Use `maxDepth` to bound memory for large state:

```swift
let undoPlugin = UndoPlugin<AppState, AppAction>(maxDepth: 50, ...)
```
