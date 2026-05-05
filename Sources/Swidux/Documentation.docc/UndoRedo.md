# Undo / Redo

Add stack-based undo/redo to your app with ``UndoPlugin``.

## Overview

``UndoPlugin`` captures state snapshots before each undoable action. Undo history lives in memory (lost on relaunch), but restored state is persisted normally via ``EntityStore``'s `restore(from:)`.

If you don't use ``UndoPlugin``, nothing changes. It's fully opt-in.

## Adding Undo to Your App

### 1. Create the middleware

```swift
private let undoPlugin = UndoPlugin<AppState, AppAction>()             // unlimited depth
private let undoPlugin = UndoPlugin<AppState, AppAction>(maxDepth: 50) // or capped
```

### 2. Classify actions

Decide which actions are undoable and which coalesce (grouping rapid calls like per-keystroke text edits into one undo step):

```swift
extension AppAction {
    var isUndoable: Bool {
        switch self {
        case .items(.create), .items(.delete), .items(.rename): true
        case .selectItem, .toggleSidebar: false
        }
    }

    var isCoalescing: Bool {
        switch self {
        case .items(.rename): true
        default: false
        }
    }
}
```

### 3. Snapshot in send()

Call `willReduce` before the reducer runs:

```swift
func send(_ action: AppAction) {
    let current = AppState(items: items, tags: tags, ui: ui)
    if action.isUndoable {
        undoPlugin.willReduce(state: current, coalescing: action.isCoalescing)
    }
    var state = current
    // ... reducer, persistence, assign-back as normal
}
```

### 4. Add undo/redo methods

Use `restore(from:)` so changes flow through persistence:

```swift
func undo() {
    let current = AppState(items: items, tags: tags, ui: ui)
    guard let restored = undoPlugin.undo(current: current) else { return }
    applySnapshot(restored)
}

func redo() {
    let current = AppState(items: items, tags: tags, ui: ui)
    guard let restored = undoPlugin.redo(current: current) else { return }
    applySnapshot(restored)
}

private func applySnapshot(_ restored: AppState) {
    var state = AppState(items: items, tags: tags, ui: ui)
    state.items.restore(from: restored.items)  // records diff for persistence
    state.tags.restore(from: restored.tags)
    state.ui = restored.ui                     // plain state — assign directly
    persistence.afterReduce(state: &state)
    items = state.items
    tags = state.tags
    ui = state.ui
}
```

### 5. Expose canUndo / canRedo

Expose these as observable properties. Call `syncUndoState()` after every `send()`, `undo()`, and `redo()`.

### 6. Wire platform UI

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
// In AppStore:
weak var undoManager: UndoManager?
// Register after undoable send():  undoManager?.registerUndo(withTarget: self) { $0.undo() }
// Register after undo():           undoManager?.registerUndo(withTarget: self) { $0.redo() }
// Register after redo():           undoManager?.registerUndo(withTarget: self) { $0.undo() }

// In view — connect the environment UndoManager:
.onAppear { store.undoManager = undoManager }
.onChange(of: undoManager) { _, new in store.undoManager = new }
```

## Coalescing

`willReduce(coalescing: true)` pushes on the first call, then skips subsequent consecutive coalescing calls — they share the original snapshot. A non-coalescing call or undo/redo resets the flag. Typing "hello" produces one undo entry, not five.

## Memory

Each snapshot is a value-type copy of `AppState`. Cost is proportional to the number of entities across all stores. Use `maxDepth` to bound memory for large state.
