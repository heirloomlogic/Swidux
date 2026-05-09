# Swidux

**Redux-style state management for SwiftUI.** State lives in one observable store, mutations go through reducers, and side effects run as async closures. Macros generate the observability boilerplate. Built-in plugins handle persistence and undo/redo. Three optional plugins ship ready-made paywalls, version killswitches, and parental gates.

## Why Swidux

- **Predictable mutations.** Reducers are pure and synchronous. Async work is explicit, off the MainActor, and dispatches results back through actions.
- **No observer-class boilerplate.** `@SwiduxState` writes the `@Observable` companion class for you. SwiftUI gets per-property observation without hand-maintained class trees.
- **Persistence is invisible.** `EntityStore` tracks every change; `PersistencePlugin` debounces and batches them. You never write `save()` in a feature. Scalar preferences (theme, sort order) get a separate testable abstraction — `KeyValueStore` — instead of reaching for `UserDefaults.standard`.
- **Batteries included.** Undo/redo, version killswitches, parental gates, and RevenueCat-shaped paywalls are one `plugins.register(...)` away.
- **Strict-concurrency-native.** Built for Swift 6 from the ground up. `Sendable`, `@MainActor`, and `@concurrent` are wired into the dispatch cycle so your app composes safely with async/await and SwiftData.

## Installation

**Xcode.** File > Add Package Dependencies, paste `https://github.com/heirloomlogic/Swidux`, set **Up to Next Major** from `1.0.0`. Add the products you need:

- `Swidux` — core
- `SwiduxKillswitch` — version-blocking plugin (optional)
- `SwiduxParentalGate` — math-challenge gate plugin (optional)
- `SwiduxPaywall` — paywall + entitlement plugin (optional)

**Package.swift.**

```swift
.package(url: "https://github.com/heirloomlogic/Swidux", from: "1.0.0"),
```

```swift
.product(name: "Swidux", package: "Swidux"),
.product(name: "SwiduxPaywall", package: "Swidux"),     // optional
.product(name: "SwiduxKillswitch", package: "Swidux"),  // optional
.product(name: "SwiduxParentalGate", package: "Swidux"),// optional
```

## Quickstart

The shape of a Swidux app, condensed:

```swift
import SwiftUI
@_exported import Swidux

@SwiduxState
nonisolated struct AppState: Equatable, Sendable {
    var counters: EntityStore<Counter> = .init()
}

enum AppAction: Sendable {
    case increment(UUID)
}

typealias AppStore = Store<AppState, AppAction>

extension Store where State == AppState, Action == AppAction {
    static func configured() -> AppStore {
        Store(initialState: AppState(), reducer: { state, action in
            if case .increment(let id) = action {
                state.counters.modify(id) { $0.count += 1 }
            }
            return nil
        })
    }
}
```

Walk through a complete counter app — actions, reducer, plugins, views, undo, async effects — in [Build Your First Swidux App](https://heirloomlogic.github.io/Swidux/documentation/swidux/buildingyourfirstapp). The runnable version of that tutorial lives at [`Examples/Counter/`](Examples/Counter/).

## Plugins

Three optional plugins ship as separate library targets. Wire any of them with three keypath/closure pieces and a `plugins.register(...)` call.

### Killswitch

Block users on outdated app versions by checking remote config (`minimumSupportedVersion`, `blockedVersions`, `blockedRanges`) against the current `CFBundleShortVersionString`. Cache-aware (`.fetch` uses the local cache when fresh; `.forceFetch` always hits the network), with cached fallback on network failure so a flaky launch still yields a usable verdict. Drop in the `killswitchBlocker(verdict:onUpdate:)` view modifier and the blocker overlays automatically when blocked. See [Add a Version Killswitch](https://heirloomlogic.github.io/Swidux/documentation/swidux/howtoaddaversionkillswitch).

```swift
plugins.register(KillswitchPlugin(state: \.killswitch, action: AppAction.killswitch, extractAction: { if case .killswitch(let a) = $0 { return a }; return nil }, service: .live(endpoint: configURL), appVersion: { Bundle.main.shortVersion }))
```

### Parental gate

Guard sensitive actions (purchases, settings changes, leaving kids mode) behind a math challenge. Passed reasons are remembered for the session — once `"purchase"` clears, subsequent `.request(reason: "purchase")` auto-pass. Plug in custom challenge generators via `ParentalChallengeSource`. See [Add a Parental Gate](https://heirloomlogic.github.io/Swidux/documentation/swidux/howtoaddaparentalgate).

```swift
plugins.register(ParentalGatePlugin(state: \.parentalGate, action: AppAction.parentalGate, extractAction: { if case .parentalGate(let a) = $0 { return a }; return nil }))
```

### Paywall

Manage paywall presentation, entitlement observation, and purchase restoration. The plugin is purchase-agnostic — it doesn't know about products or prices. You implement a `PaywallService` against StoreKit, RevenueCat, or a custom backend; the plugin handles state. For RevenueCat, drop in the ready-made adapter from [`SwiduxRevenueCatPaywall`](https://github.com/heirloomlogic/SwiduxRevenueCatPaywall) — it ships `RevenueCatPaywallService` and a SwiftUI sheet built on RevenueCatUI. Check `store.paywall.isGateSatisfied` before running a pro feature. See [Add a Paywall](https://heirloomlogic.github.io/Swidux/documentation/swidux/howtoaddapaywall).

```swift
plugins.register(PaywallPlugin(state: \.paywall, action: AppAction.paywall, extractAction: { if case .paywall(let a) = $0 { return a }; return nil }, service: RevenueCatPaywallService()))
```

### Companion packages

- [`SwiduxRevenueCatPaywall`](https://github.com/heirloomlogic/SwiduxRevenueCatPaywall) — RevenueCat adapter for `SwiduxPaywall`. Ships `RevenueCatPaywallService` (drop-in `PaywallService`), a mock for previews, and a SwiftUI sheet built on RevenueCatUI.

## Macros

`@SwiduxState` and `@SwiduxNested` eliminate the observer-class boilerplate that would otherwise sit between your value-type state and SwiftUI's `@Observable` requirement.

```swift
// Before — you'd hand-write an @Observable class mirroring AppState plus
// a SwiduxObservable conformance with pack/unpack/restore methods.

// After:
@SwiduxState
nonisolated struct AppState: Equatable, Sendable {
    var items: EntityStore<Item> = .init()
    @SwiduxNested var ui: UIState = .init()
}
```

The macros emit an `AppStateObserver` class and a `SwiduxObservable` extension. `@SwiduxNested` ensures composed state slices keep per-property observation. See [Macros Reference](https://heirloomlogic.github.io/Swidux/documentation/swidux/macrosreference).

## Documentation

Full DocC reference at https://heirloomlogic.github.io/Swidux/documentation/swidux/. Starting points by intent:

- **I want to learn** — [Build Your First Swidux App](https://heirloomlogic.github.io/Swidux/documentation/swidux/buildingyourfirstapp)
- **I want to add a paywall / killswitch / parental gate** — the three how-tos linked above
- **I want the API** — [Macros Reference](https://heirloomlogic.github.io/Swidux/documentation/swidux/macrosreference), [EntityStore Guide](https://heirloomlogic.github.io/Swidux/documentation/swidux/entitystoreguide), [Persistence Middleware Guide](https://heirloomlogic.github.io/Swidux/documentation/swidux/persistencemiddlewareguide), [KeyValueStore Guide](https://heirloomlogic.github.io/Swidux/documentation/swidux/keyvaluestoreguide), [Undo / Redo](https://heirloomlogic.github.io/Swidux/documentation/swidux/undoredo)
- **I want to understand the design** — [Architecture Guide](https://heirloomlogic.github.io/Swidux/documentation/swidux/architectureguide), [Plugin Architecture](https://heirloomlogic.github.io/Swidux/documentation/swidux/pluginarchitecture), [Design Principles](https://heirloomlogic.github.io/Swidux/documentation/swidux/designprinciples)
- **I want to write my own plugin** — [Building a Domain Plugin](https://heirloomlogic.github.io/Swidux/documentation/swidux/buildingadomainplugin)

## Installing the agent skill

Swidux ships an AI-assistant skill at `.claude/skills/swidux-ref/` containing the architecture rules and copy-pasteable code templates. Claude Code does **not** auto-discover skills inside Swift Package dependencies — you have to install it explicitly.

**Personal install (all your projects):**

```bash
git clone https://github.com/heirloomlogic/Swidux ~/code/Swidux
ln -s ~/code/Swidux/.claude/skills/swidux-ref ~/.claude/skills/swidux-ref
```

**Project install (commit for the team):**

```bash
mkdir -p .claude/skills
cp -R path/to/Swidux/.claude/skills/swidux-ref .claude/skills/
git add .claude/skills/swidux-ref
```

For other AI assistants, point your context at `swidux-ref/SKILL.md` and `swidux-ref/swidux-patterns.md`. See the [Agent Skill](https://heirloomlogic.github.io/Swidux/documentation/swidux/agentskill) article for details.

## Requirements

Swift 6.2+ / Xcode 26+, macOS 15+ / iOS 18+. Strict concurrency (`.swiftLanguageMode(.v6)`).

## License

See [LICENSE](LICENSE) for details.
