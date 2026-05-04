# Swidux Plugin System Design

## Context

HeirloomGate provides paywall, killswitch, and parental gate functionality for Heirloom Logic apps. It integrates with Swidux through a 5-step manual process (state, actions, reducer, services, store conformance). Meanwhile, Swidux's own PersistenceMiddleware and UndoMiddleware are ad-hoc classes with no shared contract.

This design unifies all of these under a single plugin protocol. Swidux core becomes a minimal unidirectional data flow engine, with persistence, undo, killswitch, paywall, and parental gate as opt-in plugins. HeirloomGate is retired; its features move into Swidux as three independent plugin targets.

## Plugin Protocol

One protocol. All lifecycle methods have default empty implementations.

```swift
@MainActor
public protocol SwiduxPlugin<State, Action> {
    associatedtype State
    associatedtype Action

    /// Called before the app reducer runs. Undo snapshots here.
    func willReduce(state: State, action: Action)

    /// Handle action after the app reducer. Feature plugins route here.
    func reduce(state: inout State, action: Action) -> Effect<Action>?

    /// Called after all reducing is done. Persistence drains ChangeSets here.
    func afterReduce(state: inout State, action: Action)

    /// Shutdown hook. Persistence flushes pending writes here.
    func flush() async
}
```

Each plugin implements only the hooks it needs:

| Plugin | willReduce | reduce | afterReduce | flush |
|--------|-----------|--------|-------------|-------|
| PersistencePlugin | — | — | drain ChangeSets | flush writes |
| UndoPlugin | snapshot (action-filtered) | — | — | — |
| KillswitchPlugin | — | route killswitch actions | — | — |
| PaywallPlugin | — | route paywall actions | — | — |
| ParentalGatePlugin | — | route parental actions | — | — |

## PluginHost

Manages an ordered array of plugins and drives the lifecycle.

```swift
@MainActor
public final class PluginHost<State, Action> {
    private(set) public var plugins: [any SwiduxPlugin<State, Action>] = []

    public init() {}

    public func register(_ plugin: some SwiduxPlugin<State, Action>) {
        plugins.append(plugin)
    }

    public func willReduce(state: State, action: Action) {
        for plugin in plugins { plugin.willReduce(state: state, action: action) }
    }

    public func reduce(state: inout State, action: Action) -> [Effect<Action>] {
        plugins.compactMap { $0.reduce(state: &state, action: action) }
    }

    public func afterReduce(state: inout State, action: Action) {
        for plugin in plugins { plugin.afterReduce(state: &state, action: action) }
    }

    public func flush() async {
        for plugin in plugins { await plugin.flush() }
    }
}
```

- Registration order = execution order
- Append-only (plugins wired at init, never removed)
- `plugins` is public read-only for testability

## AppStore Integration

The dispatch cycle becomes:

```swift
func send(_ action: AppAction) {
    var state = pack()

    plugins.willReduce(state: state, action: action)
    let appEffect = reducer.reduce(state: &state, action: action, environment: env)
    let pluginEffects = plugins.reduce(state: &state, action: action)
    plugins.afterReduce(state: &state, action: action)

    unpack(state)

    if let appEffect {
        Task { @concurrent in await appEffect(self.send) }
    }
    for effect in pluginEffects {
        Task { @concurrent in await effect(self.send) }
    }
}
```

The app still has its own reducer (AppReducer) for business logic with Environment and feature-reducer composition. Plugins extend the cycle around it.

Registration in AppStore init:

```swift
plugins.register(UndoPlugin(isUndoable: { ... }, coalescing: { ... }))
plugins.register(PersistencePlugin(writers: [...]))
plugins.register(KillswitchPlugin(state: \.killswitch, ...))
plugins.register(PaywallPlugin(state: \.paywall, service: revenueCatService))
plugins.register(ParentalGatePlugin(state: \.parentalGate, ...))
```

## Built-in Plugin Migration

### PersistencePlugin (was PersistenceMiddleware)

Rename class, add unused `Action` type parameter, move `afterReduce`/`flush` to protocol conformance. Internal logic (writers, debounce, loop detection) unchanged.

```swift
@MainActor
public final class PersistencePlugin<State, Action>: SwiduxPlugin {
    // ... existing internals unchanged ...

    public func afterReduce(state: inout State, action: Action) {
        // existing drain + debounce logic
    }

    public func flush() async {
        // existing flush logic
    }
}
```

### UndoPlugin (was UndoMiddleware)

Gains action-based filtering. Coalescing decisions move from imperative app code to declarative predicates at init:

```swift
@MainActor
public final class UndoPlugin<State: Equatable & Sendable, Action>: SwiduxPlugin {
    private let isUndoable: @Sendable (Action) -> Bool
    private let isCoalescing: @Sendable (Action) -> Bool
    // ... existing undo/redo stacks ...

    public init(
        maxDepth: Int = .max,
        isUndoable: @escaping @Sendable (Action) -> Bool,
        coalescing: @escaping @Sendable (Action) -> Bool = { _ in false }
    ) { ... }

    public func willReduce(state: State, action: Action) {
        guard isUndoable(action) else { return }
        // existing snapshot logic, using isCoalescing(action)
    }

    // undo(current:) and redo(current:) remain direct methods
}
```

## Gate Plugins (from HeirloomGate)

HeirloomGate is retired. Its three features become independent Swidux plugin targets with zero external dependencies.

### Package Structure

```
Swidux/
├── Sources/
│   ├── Swidux/                  ← Core + PersistencePlugin + UndoPlugin
│   ├── SwiduxKillswitch/        ← depends: Swidux
│   ├── SwiduxParentalGate/      ← depends: Swidux
│   └── SwiduxPaywall/           ← depends: Swidux
```

### Plugin Pattern

Each gate plugin follows the same pattern (KillswitchPlugin shown):

```swift
public struct KillswitchPlugin<RootState, RootAction>: SwiduxPlugin {
    public typealias State = RootState
    public typealias Action = RootAction

    private let stateKeyPath: WritableKeyPath<RootState, KillswitchState>
    private let toRootAction: @Sendable (KillswitchAction) -> RootAction
    private let extractAction: @Sendable (RootAction) -> KillswitchAction?
    private let service: KillswitchService
    private let appVersion: @Sendable () -> SemanticVersion

    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        // existing KillswitchReducer logic, lifted to RootAction
    }
}
```

### PaywallPlugin — Provider Agnostic

PaywallPlugin defines a `PaywallService` protocol. The app provides a concrete implementation (RevenueCat, vanilla StoreKit, or custom). RevenueCat never appears in Swidux's dependency graph.

```swift
// In SwiduxPaywall:
public protocol PaywallService: Sendable {
    func customerInfo() async throws -> EntitlementSnapshot
    var customerInfoStream: AsyncStream<EntitlementSnapshot> { get }
    func restorePurchases() async throws
}

// In app code:
struct RevenueCatPaywallService: PaywallService { ... }
struct StoreKitPaywallService: PaywallService { ... }
```

### App-Side Wiring (per plugin)

```swift
// AppState:
var killswitch = KillswitchState()
var paywall = PaywallState()
var parentalGate = ParentalGateState()

// AppAction:
case killswitch(KillswitchAction)
case paywall(PaywallAction)
case parental(ParentalGateAction)

// Registration:
plugins.register(KillswitchPlugin(
    state: \.killswitch,
    action: AppAction.killswitch,
    extractAction: { if case .killswitch(let a) = $0 { return a }; return nil },
    service: killswitchService,
    appVersion: { .current }
))
```

### UI Stays Explicit

Each gate plugin provides SwiftUI view modifiers applied at the root view. UI composition is not automated through the plugin protocol — it stays explicit per-plugin.

## Observation Strategy (Future)

The plugin system is observation-agnostic. Plugins operate on `inout State` and don't know how the store bridges observation. A future `@SwiduxStore` macro or `@ObservableState`-style approach can eliminate pack/unpack without touching any plugin code.

## What Stays Unchanged

- `SwiduxReducer` protocol — still used for feature-reducer composition inside the app
- `SwiduxDispatcher` protocol — still the store's dispatch contract
- `EntityStore`/`ChangeSet`/`StateWriter` — still the value-layer change tracking
- `Effect`/`Send` type aliases — still the async effect system
- The pack/unpack pattern — still app-side (observation-agnostic plugins)

## Decisions

- Single flat protocol (not layered) — PersistencePlugin carries unused Action type param; accepted trade-off for unified model
- UndoPlugin uses declarative action predicates instead of imperative per-action coalescing calls
- Gate plugins are separate targets (not bundled) — true a la carte
- PaywallPlugin is provider-agnostic via PaywallService protocol — no RevenueCat dependency
- UIPlugin protocol deferred — ViewModifier composition doesn't generalize well; UI stays explicit
