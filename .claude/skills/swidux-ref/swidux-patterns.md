# Swidux Code Patterns

Copy-pasteable templates for every layer of a Swidux app. Pair with `SKILL.md` for the rules.

## File layout

```
MyApp/
├── App/
│   ├── AppState.swift       // @Swidux struct + @_exported import Swidux
│   ├── AppAction.swift      // root AppAction enum, feature action enums
│   ├── AppReducer.swift     // root reducer that routes to feature reducers
│   ├── AppStore.swift       // typealias + Store.configured() factory
│   ├── AppEnvironment.swift // dependencies (DB actors, services)
│   └── Effect.swift         // typealias Send / Effect specialized to AppAction
├── Features/
│   └── <Feature>Reducer.swift
├── Models/
│   └── <Model>.swift        // EntityStore-compatible Identifiable Equatable Sendable
└── Views/
    ├── ContentView.swift
    └── <Feature>View.swift
```

## App/AppState.swift

```swift
import Foundation
@_exported import Swidux

@Swidux
nonisolated struct AppState: Equatable, Sendable {
    var items: EntityStore<Item> = .init()
    @Slice var ui: UIState = .init()

    init(items: EntityStore<Item> = .init(), ui: UIState = .init()) {
        self.items = items
        self.ui = ui
    }
}

@Swidux
nonisolated struct UIState: Equatable, Sendable {
    var selectedItemID: UUID? = nil
}
```

## App/AppAction.swift

```swift
import Foundation

enum AppAction: Sendable {
    case items(ItemAction)
    case selectItem(UUID?)
}

enum ItemAction: Sendable {
    case add
    case remove(UUID)
    case setName(UUID, String)
    case incrementCount(UUID)
    case incrementCountAsync(UUID)
}
```

## App/Effect.swift

```swift
typealias Send = Swidux.Send<AppAction>
typealias Effect = Swidux.Effect<AppAction>
```

## App/AppEnvironment.swift

```swift
import Foundation

struct AppEnvironment: Sendable {
    var save: @Sendable (Item) async throws -> Void
    var delete: @Sendable (UUID) async throws -> Void

    static func live() -> AppEnvironment {
        AppEnvironment(
            save: { item in /* DB actor call */ },
            delete: { id in /* DB actor call */ }
        )
    }

    static func mock() -> AppEnvironment {
        AppEnvironment(save: { _ in }, delete: { _ in })
    }
}
```

## App/AppReducer.swift

```swift
import Foundation

struct AppReducer: SwiduxReducer {
    let item = ItemReducer()

    func reduce(
        state: inout AppState,
        action: AppAction,
        environment: AppEnvironment
    ) -> Effect? {
        switch action {
        case .items(let action):
            return item.reduce(state: &state, action: action, environment: environment)
        case .selectItem(let id):
            state.ui.selectedItemID = id
            return nil
        }
    }
}
```

## Features/ItemReducer.swift

```swift
import Foundation

struct ItemReducer: SwiduxReducer {
    typealias Action = ItemAction
    typealias RootAction = AppAction

    func reduce(
        state: inout AppState,
        action: ItemAction,
        environment: AppEnvironment
    ) -> Effect? {
        switch action {
        case .add:
            let item = Item(id: UUID(), name: "New", count: 0)
            state.items[item.id] = item    // subscript setter records upsert
            return nil

        case .remove(let id):
            state.items.removeAll(where: { $0.id == id })
            return nil

        case .setName(let id, let name):
            state.items.modify(id) { $0.name = name }
            return nil

        case .incrementCount(let id):
            state.items.modify(id) { $0.count += 1 }
            return nil

        case .incrementCountAsync(let id):
            return { send in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await send(.items(.incrementCount(id)))
            }
        }
    }
}
```

## App/AppStore.swift

```swift
import SwiftUI
import os

typealias AppStore = Store<AppState, AppAction>

extension Store where State == AppState, Action == AppAction {
    static func configured(environment: AppEnvironment = .live()) -> AppStore {
        let reducer = AppReducer()
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "app",
            category: "swidux"
        )

        let isUndoable: @Sendable (AppAction) -> Bool = { action in
            switch action {
            case .items(.add), .items(.remove), .items(.setName), .items(.incrementCount):
                true
            case .items(.incrementCountAsync), .selectItem:
                false
            }
        }

        let undoPlugin = UndoPlugin<AppState, AppAction>(
            isUndoable: isUndoable,
            coalescing: { action in
                if case .items(.setName) = action { return true }
                return false
            }
        )

        let persistencePlugin = PersistencePlugin<AppState, AppAction>(
            writers: [
                StateWriter(keyPath: \.items) { writes, deletes in
                    for item in writes { try? await environment.save(item) }
                    for id in deletes  { try? await environment.delete(id) }
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

## CounterApp.swift (entry point)

```swift
import SwiftUI

@main
struct MyApp: App {
    @State private var store = AppStore.configured()

    var body: some Scene {
        WindowGroup {
            ContentView().environment(store)
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

## Views/ContentView.swift

```swift
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List(store.items.values) { item in
            ItemRow(itemID: item.id)
        }
        .toolbar {
            Button("Add") { store.send(.items(.add)) }
        }
    }
}

struct ItemRow: View {
    @Environment(AppStore.self) private var store
    let itemID: UUID

    var body: some View {
        let item = store.items[itemID]
        HStack {
            TextField(
                "Name",
                text: Binding(
                    get: { item?.name ?? "" },
                    set: { store.send(.items(.setName(itemID, $0))) }
                )
            )
            Spacer()
            Text("\(item?.count ?? 0)")
            Button("+") { store.send(.items(.incrementCount(itemID))) }
        }
    }
}
```

## Models/Item.swift

```swift
import Foundation

struct Item: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var count: Int
}
```

## Wiring KillswitchPlugin

Add a state slice + action case, then register the plugin:

```swift
// AppState.swift
@Swidux
nonisolated struct AppState: Equatable, Sendable {
    @Slice var killswitch: KillswitchState = .init()
    // … other slices
}

// AppAction.swift
enum AppAction: Sendable {
    case killswitch(KillswitchAction)
    // … other cases
}

// AppReducer.swift — domain plugins handle their own reduce hook,
// but the root reducer should fall through (return nil) for plugin actions.
case .killswitch:
    return nil

// AppStore.swift — inside Store.configured()
let killswitchPlugin = KillswitchPlugin<AppState, AppAction>(
    state: \.killswitch,
    action: AppAction.killswitch,
    extractAction: { if case .killswitch(let a) = $0 { return a }; return nil },
    service: KillswitchService.live(
        endpoint: URL(string: "https://example.com/killswitch.json")!
    ),
    appVersion: {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
)
plugins.register(killswitchPlugin)
```

Trigger a cache-aware fetch on launch and let the bundled view modifier
render the blocker (use `.forceFetch` for pull-to-refresh):

```swift
ContentView()
    .task { store.send(.killswitch(.fetch)) }
    .killswitchBlocker(verdict: store.killswitch.verdict) {
        store.send(.killswitch(.openUpdateURL))
    }
```

`.fetch` consults the cache and skips the network when fresh. On network
failure, the plugin falls back to the cached config: dispatches
`.verdictReceived(...)` from cache **and** `.fetchFailed(message)`, so the
UI keeps a usable verdict while exposing the error.

## Wiring PaywallPlugin

```swift
// AppState.swift
@Slice var paywall: PaywallState = .init()

// AppAction.swift
case paywall(PaywallAction)

// AppStore.swift
let paywallPlugin = PaywallPlugin<AppState, AppAction>(
    state: \.paywall,
    action: AppAction.paywall,
    extractAction: { if case .paywall(let a) = $0 { return a }; return nil },
    service: RevenueCatPaywallService()  // your conformer to PaywallService
)
plugins.register(paywallPlugin)
```

```swift
// In a view: observe + gate a feature
.task { store.send(.paywall(.observeCustomerInfo)) }

Button("Pro Feature") {
    if store.paywall.isGateSatisfied {
        // run pro feature
    } else {
        store.send(.paywall(.request(reason: "pro-feature")))
    }
}
.sheet(isPresented: Binding(
    get: { store.paywall.isPresented },
    set: { if !$0 { store.send(.paywall(.dismiss)) } }
)) {
    PaywallSheet()
}
```

## Wiring ParentalGatePlugin

```swift
// AppState.swift
@Slice var parentalGate: ParentalGateState = .init()

// AppAction.swift
case parentalGate(ParentalGateAction)

// AppStore.swift
let parentalGatePlugin = ParentalGatePlugin<AppState, AppAction>(
    state: \.parentalGate,
    action: AppAction.parentalGate,
    extractAction: { if case .parentalGate(let a) = $0 { return a }; return nil },
    challengeSource: .standard
)
plugins.register(parentalGatePlugin)
```

```swift
// Gate an action behind a passed reason
Button("Buy gems") {
    if store.parentalGate.passedReasons.contains("purchase") {
        store.send(.shop(.buyGems))
    } else {
        store.send(.parentalGate(.request(reason: "purchase")))
    }
}

.sheet(isPresented: Binding(
    get: { store.parentalGate.pendingReason != nil },
    set: { if !$0 { store.send(.parentalGate(.dismiss)) } }
)) {
    ParentalGateSheet()
}
```

In a feature reducer that listens for `answerAccepted`:

```swift
case .parentalGate(.answerAccepted(let reason)) where reason == "purchase":
    return { send in await send(.shop(.buyGems)) }
```

## Reducer test (Swift Testing)

```swift
import Testing
@testable import MyApp

@MainActor
struct ItemReducerTests {
    @Test func incrementCount_mutatesEntity() async throws {
        var state = AppState(items: EntityStore([
            Item(id: UUID(), name: "A", count: 0)
        ]))
        let id = state.items.values[0].id
        let reducer = ItemReducer()

        let effect = reducer.reduce(
            state: &state,
            action: .incrementCount(id),
            environment: .mock()
        )

        #expect(effect == nil)
        #expect(state.items[id]?.count == 1)
    }

    @Test func incrementCountAsync_returnsEffectThatDispatchesIncrement() async throws {
        var state = AppState(items: EntityStore([
            Item(id: UUID(), name: "A", count: 0)
        ]))
        let id = state.items.values[0].id
        let reducer = ItemReducer()

        let effect = reducer.reduce(
            state: &state,
            action: .incrementCountAsync(id),
            environment: .mock()
        )
        let effect = try #require(effect)

        var dispatched: [AppAction] = []
        await effect { dispatched.append($0) }

        #expect(dispatched == [.items(.incrementCount(id))])
    }
}
```

## Plugin integration test

```swift
@MainActor
@Test func killswitch_blockedVersion_setsBlockedVerdict() async throws {
    var state = AppState()
    let reducer = AppReducer()
    let plugin = KillswitchPlugin<AppState, AppAction>(
        state: \.killswitch,
        action: AppAction.killswitch,
        extractAction: { if case .killswitch(let a) = $0 { return a }; return nil },
        service: .mock(result: {
            KillswitchConfig(minimumSupportedVersion: "2.0.0")
        }),
        appVersion: { "1.0.0" }
    )

    let effect = plugin.reduce(state: &state, action: .killswitch(.fetch))
    let effect = try #require(effect)

    var dispatched: [AppAction] = []
    await effect { dispatched.append($0) }

    if case .killswitch(.verdictReceived(.blocked)) = dispatched.first {
        // pass
    } else {
        Issue.record("expected blocked verdict, got \(dispatched)")
    }
}
```

## FeatureFlagsPlugin wiring

Feature flags + A/B variants + remote-tunable values from one JSON wire format.

### State slice

```swift
import SwiduxFeatureFlags

@Swidux
nonisolated struct AppState: Equatable, Sendable {
    @Slice var featureFlags: FeatureFlagsState = .init()
    // ... your other slices
}
```

### Action case

```swift
enum AppAction: Sendable {
    case featureFlags(FeatureFlagsAction)
    // ...
}
```

### Plugin registration

```swift
let kv: any KeyValueStore = UserDefaultsKeyValueStore()
let initial = AppState(featureFlags: .hydrated(from: kv))
let store = AppStore(initialState: initial, reducer: AppReducer())

let flags = FeatureFlagsPlugin<AppState, AppAction>(
    state: \.featureFlags,
    action: AppAction.featureFlags,
    extractAction: { if case .featureFlags(let a) = $0 { return a } else { return nil } },
    service: HTTPFeatureFlagsService(url: configURL),
    userIDKeyPath: \.session.userID,
    refreshPolicy: .automatic,
    keyValueStore: kv,
    onExposure: { key, value in
        Task { @MainActor in
            store.send(.analytics(.track(AnalyticsEvent("feature_flag_exposed", [
                "flag_key": .string(key)
            ]))))
        }
    }
)
store.register(plugin: flags)
```

### Typed flag-key declarations

```swift
extension BoolFlag {
    static let newOnboarding = BoolFlag("new_onboarding")
}

enum CheckoutVariant: String { case control, treatment }

extension VariantFlag where Variant == CheckoutVariant {
    static let checkoutLayout = VariantFlag("checkout_layout", default: .control)
}

extension ValueFlag where Value == Int {
    static let maxFreeUploads = ValueFlag("max_free_uploads", default: 5)
}
```

### Reading at a call site

```swift
if store.featureFlags.isEnabled(.newOnboarding) { NewOnboardingView() }

let layout = store.featureFlags.variant(of: .checkoutLayout)
let cap = store.featureFlags.value(of: .maxFreeUploads)
```

### Exposure tracking

```swift
WizardView()
    .recordsExposure(of: .checkoutLayout, store: store, action: AppAction.featureFlags)
```

Plugin dedupes per session. Wire `onExposure` (above) to forward exposures to your analytics plugin.

### Foreground refresh

```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .active { store.send(.featureFlags(.refresh)) }
}
```

`.automatic` refresh policy debounces against `lastFetchedAt + minInterval` (default 300s) so this is safe to dispatch frequently.
