# Build Your First Swidux App

Build a counter app from scratch and meet the four moving parts of a Swidux project: state, action, reducer, and store.

## Overview

By the end of this tutorial you'll have a working SwiftUI app that manages a list of named counters. You can add and remove counters, increment and decrement, rename via `TextField`, kick off an async increment that fires after a one-second delay, and undo or redo any change with the standard menubar shortcuts. The end-state mirrors the app under `Examples/Counter/` in the Swidux repo, so you can diff your work against it.

## What you'll build

A small macOS/iOS app with:

- A list of counters, each with a name and an integer value.
- A toolbar `+` button that adds a new counter.
- Per-row buttons for increment, decrement, and async-increment.
- A `TextField` per row that renames the counter.
- Tap to select a counter — the row highlights.
- Undo and redo (cmd-Z / shift-cmd-Z on macOS).

## What you'll learn

- Defining state with `@Swidux` and `@Slice`.
- Designing actions as nested enums.
- Writing reducers that mutate state via `inout`.
- Returning effects for async work.
- Wiring a ``Store`` with plugins for undo and persistence logging.
- Reading state from views via `@dynamicMemberLookup`.

## Step 1: Create the project and add Swidux

In Xcode, create a new SwiftUI app project. Then add Swidux as a package dependency: **File > Add Package Dependencies**, paste `https://github.com/heirloomlogic/Swidux`, choose **Up to Next Major** from `1.0.0`.

You'll re-export Swidux from one file so the rest of the app doesn't need to import it.

## Step 2: Define the model

A counter has an ID, a name, and an integer count. Make it `Identifiable`, `Equatable`, and `Sendable` — ``EntityStore`` requires all three.

```swift
// Models/Counter.swift
import Foundation

nonisolated struct Counter: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var count: Int

    init(id: UUID = UUID(), name: String = "Counter", count: Int = 0) {
        self.id = id
        self.name = name
        self.count = count
    }
}
```

## Step 3: Define the state

There are two state slices: a collection of counters, and a UI slice that tracks which counter is selected. Both get `@Swidux`. The parent uses `@Slice` on the UI slice so the macro wires it as a separate observer instead of an opaque leaf — see <doc:MacrosReference> for the why.

This file is the one place you import Swidux. Re-export it so no other file has to.

```swift
// App/AppState.swift
import Foundation
@_exported import Swidux

@Swidux
nonisolated struct AppState: Equatable, Sendable {
    var counters: EntityStore<Counter> = .init()
    @Slice var ui: UIState = .init()

    init(counters: EntityStore<Counter> = EntityStore(), ui: UIState = UIState()) {
        self.counters = counters
        self.ui = ui
    }
}

@Swidux
nonisolated struct UIState: Equatable, Sendable {
    var selectedCounterID: UUID? = nil
}
```

``EntityStore`` is Swidux's keyed collection — like an ordered dictionary, with built-in change tracking for persistence and undo.

## Step 4: Define the actions

Every user interaction and every effect callback is expressed as a value of `AppAction`. Splitting into nested enums (`AppAction` -> `CounterAction`) keeps each feature's actions colocated and makes the root reducer's `switch` shallow.

```swift
// App/AppAction.swift
import Foundation

enum AppAction: Sendable {
    case counter(CounterAction)
    case selectCounter(UUID?)
}

enum CounterAction: Sendable {
    case add
    case remove(UUID)
    case increment(UUID)
    case decrement(UUID)
    case incrementAsync(UUID)
    case setName(UUID, String)
}
```

## Step 5: Specialize the effect typealiases

Swidux's effect system is generic over your action type. Pin it to `AppAction` once so you don't repeat the generic parameters everywhere.

```swift
// App/Effect.swift
import Foundation

typealias Send = Swidux.Send<AppAction>
typealias Effect = Swidux.Effect<AppAction>
```

`Send` is `@MainActor @Sendable (AppAction) -> Void`. `Effect` is a `@Sendable` async closure that takes a `Send`. Effects are returned from the reducer when an action needs to do async work.

You'll also want an environment type to hold injected dependencies. The Counter demo has none, so it's a placeholder:

```swift
// App/AppEnvironment.swift
import Foundation

struct AppEnvironment: Sendable {
    static func live() -> AppEnvironment { .init() }
    static func mock() -> AppEnvironment { .init() }
}
```

## Step 6: Write the reducer

The reducer is a pure function from `(state, action, environment)` to an optional `Effect`. State mutates via `inout`. Any case that doesn't need async work returns `nil`.

Start with the per-feature reducer. The interesting case is `incrementAsync`: it returns an effect that sleeps for a second, then dispatches a synchronous `increment`.

```swift
// Features/CounterReducer.swift
import Foundation

struct CounterReducer: SwiduxReducer {
    func reduce(
        state: inout AppState,
        action: CounterAction,
        environment: AppEnvironment
    ) -> Effect? {
        switch action {
        case .add:
            let counter = Counter(name: "Counter \(state.counters.count + 1)")
            state.counters[counter.id] = counter

        case .remove(let id):
            state.counters[id] = nil

        case .increment(let id):
            state.counters.modify(id) { $0.count += 1 }

        case .decrement(let id):
            state.counters.modify(id) { $0.count = max(0, $0.count - 1) }

        case .incrementAsync(let id):
            return { send in
                try? await Task.sleep(for: .seconds(1))
                await send(.counter(.increment(id)))
            }

        case .setName(let id, let name):
            state.counters.modify(id) { $0.name = name }
        }

        return nil
    }
}
```

Then the root reducer, which routes `AppAction` cases to feature reducers and handles top-level cases inline.

```swift
// App/AppReducer.swift
import Foundation

struct AppReducer: SwiduxReducer {
    let counter = CounterReducer()

    func reduce(
        state: inout AppState,
        action: AppAction,
        environment: AppEnvironment
    ) -> Effect? {
        switch action {
        case .counter(let action):
            return counter.reduce(state: &state, action: action, environment: environment)

        case .selectCounter(let id):
            state.ui.selectedCounterID = id
        }

        return nil
    }
}
```

## Step 7: Wire the store

``Store`` owns the dispatch loop, plugin lifecycle, and observer tree. Build it from a factory method so views and previews get the same wiring. Register two plugins:

- ``UndoPlugin`` records snapshots before each undoable action. The `isUndoable` predicate decides which actions count; `coalescing` collapses runs of the same action (so typing into the rename field doesn't create one undo entry per keystroke).
- ``PersistencePlugin`` is registered with a `StateWriter` over `\.counters`. The Counter demo just logs the writes — in a real app you'd persist to a database.

```swift
// App/AppStore.swift
import SwiftUI
import os

typealias AppStore = Store<AppState, AppAction>

extension Store where State == AppState, Action == AppAction {
    static func configured(environment: AppEnvironment = .live()) -> AppStore {
        let reducer = AppReducer()
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "counter",
            category: "persistence"
        )

        let isUndoable: @Sendable (AppAction) -> Bool = { action in
            switch action {
            case .counter(.add), .counter(.remove),
                 .counter(.increment), .counter(.decrement),
                 .counter(.setName):
                true
            case .counter(.incrementAsync), .selectCounter:
                false
            }
        }

        let undoPlugin = UndoPlugin<AppState, AppAction>(
            isUndoable: isUndoable,
            coalescing: { action in
                if case .counter(.setName) = action { return true }
                return false
            }
        )

        let persistencePlugin = PersistencePlugin<AppState, AppAction>(
            writers: [
                StateWriter(keyPath: \.counters) { writes, deletes in
                    for counter in writes {
                        logger.info("Persist upsert: \(counter.name) = \(counter.count)")
                    }
                    for id in deletes {
                        logger.info("Persist delete: \(id)")
                    }
                }
            ],
            logger: logger
        )

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
    }
}
```

## Step 8: Build the views

Views read from the store via `@Environment` and dispatch actions with `store.send(...)`. They never import Swidux directly (the re-export from `AppState.swift` handles that).

The list view binds to `store.counters.values` — `@dynamicMemberLookup` forwards through to the generated observer class, so SwiftUI observation picks up changes per slice.

```swift
// Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationStack {
            List(store.counters.values) { counter in
                CounterRow(counterID: counter.id)
                    .listRowBackground(
                        store.ui.selectedCounterID == counter.id
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.send(.selectCounter(counter.id))
                    }
            }
            .navigationTitle("Counters")
            .toolbar {
                Button("Add Counter", systemImage: "plus") {
                    store.send(.counter(.add))
                }
            }
            .overlay {
                if store.counters.isEmpty {
                    ContentUnavailableView(
                        "No Counters",
                        systemImage: "number.square",
                        description: Text("Tap + to add a counter.")
                    )
                }
            }
            .onAppear { store.undoManager = undoManager }
            .onChange(of: undoManager) { _, new in store.undoManager = new }
        }
    }
}
```

The row takes a `counterID` rather than the full `Counter`. That lets SwiftUI skip re-evaluation of unchanged rows when the parent's body runs. The `TextField` is **controlled**: the binding goes straight through the store. There's no local `@State` — the store is the single source of truth.

```swift
// Views/CounterRow.swift
import SwiftUI

struct CounterRow: View {
    @Environment(AppStore.self) private var store
    let counterID: UUID

    var body: some View {
        if let counter = store.counters[counterID] {
            HStack {
                TextField(
                    "Name",
                    text: Binding(
                        get: { counter.name },
                        set: { store.send(.counter(.setName(counterID, $0))) }
                    )
                )
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Text("\(counter.count)")
                    .font(.title2.monospacedDigit())
                    .frame(minWidth: 40)

                Button {
                    store.send(.counter(.decrement(counterID)))
                } label: {
                    Image(systemName: "minus.circle")
                }

                Button {
                    store.send(.counter(.increment(counterID)))
                } label: {
                    Image(systemName: "plus.circle")
                }

                Button {
                    store.send(.counter(.incrementAsync(counterID)))
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Increment after 1 second delay")
            }
            .buttonStyle(.borderless)
        }
    }
}
```

## Step 9: Wire the app entry

Own the store with `@State` so it survives `Scene` body re-evaluations. Inject it via `.environment()`. On macOS, replace the standard undo command group so cmd-Z talks to ``Store/undo()`` instead of the system undo manager.

```swift
// CounterApp.swift
import SwiftUI

@main
struct CounterApp: App {
    @State private var store = AppStore.configured()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
        #if os(macOS)
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
        #endif
    }
}
```

## Run it

Build and run. You should see an empty list with "No Counters" placeholder text. Click `+` in the toolbar — a row appears. Click `+` again — a second row. Click on a row — its background tints with the accent color. Click `+` (per-row) to increment the count, `-` to decrement, the clock icon to increment after one second. Edit the name field — the rename persists immediately (and the persistence plugin logs each upsert to the console).

On macOS, hit cmd-Z to undo. Each add, remove, increment, decrement, and rename should reverse one step at a time. Renames coalesce — a single undo restores the whole previous name, not one keystroke. Hit shift-cmd-Z to redo.

## What just happened

Four parts wired together. **Views** render from `store.counters` and `store.ui` and dispatch actions through `store.send(...)`. **Actions** (`AppAction`, `CounterAction`) describe what happened. The **reducer** translates actions into state mutations, optionally returning an **effect** for async work. The **store** runs the dispatch loop: it packs the observer tree into a struct snapshot, hands it to your reducer, then unpacks the result back onto the observer — firing per-property observation only for fields that actually changed.

The async increment shows the round trip. A button click dispatches `.counter(.incrementAsync(id))`. The reducer returns an effect that sleeps off the MainActor, then calls `send(.counter(.increment(id)))`. That second dispatch goes through the same loop, hits the synchronous `.increment` case, and updates the counter — which fires observation and re-renders just that row's count label.

## Next steps

- <doc:HowToAddAPaywall> — gate features behind a subscription.
- <doc:HowToAddAVersionKillswitch> — force-update unsupported app versions.
- <doc:HowToAddAParentalGate> — block underage purchases.
- <doc:MacrosReference> — full reference for `@Swidux` and `@Slice`.
- <doc:ArchitectureGuide> — the snapshot/observer pattern and its performance characteristics.
- <doc:PluginArchitecture> — write your own plugin.
