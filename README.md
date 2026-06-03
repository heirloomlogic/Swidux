<p align="center">
  <img src="Sources/Swidux/Documentation.docc/Resources/Swidux-logo@2x.png" alt="Swidux" width="256">
</p>

# Swidux

**Redux-style state management for SwiftUI.** State lives in one observable store, mutations go through reducers, and side effects run as async closures. Macros generate the observability boilerplate. Built-in plugins handle persistence and undo/redo. Three optional plugins ship ready-made paywalls, version killswitches, and parental gates.

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%20|%20iOS%20|%20tvOS%20|%20watchOS%20-blue.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/Documentation-DocC-blue.svg)](https://heirloomlogic.github.io/Swidux/documentation/swidux/)

## Why Swidux

- **Predictable mutations.** Reducers are pure and synchronous. Async work is explicit, off the MainActor, and dispatches results back through actions.
- **No observer-class boilerplate.** `@Swidux` writes the `@Observable` companion class for you. SwiftUI gets per-property observation without hand-maintained class trees.
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

@Swidux
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

Optional plugins ship as separate library targets. Wire any of the cross-cutting ones with three keypath/closure pieces and a `plugins.register(...)` call; the persistence pair is registered through a coordinator.

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

### Persistence (SwiftData)

`SwiduxPersistence` makes SwiftData persistence a declare-and-register concern. Annotate a domain entity with `@Persisted` and the macro generates its `@Model` shadow class, the `init(from:)`/`toDomain()`/`update(from:)` converters, and the `PersistableEntity` conformance — no hand-written model, DB actor, or `StateWriter`. A generic `EntityDB` actor and a `PersistenceCoordinator` (which reuses the core `PersistencePlugin`) handle the container, writers, and a merge-only re-hydration path.

```swift
@Persisted struct Card: Identifiable, Equatable, Sendable { var id: UUID; var quote: String }

let container = try ContainerFactory.makeLocalContainer(models: [CardModel.self])
let persistence = PersistenceCoordinator<AppState, AppAction>(entities: [.entity(\.cards)], container: container)
plugins.register(persistence.corePlugin)
await persistence.hydrate(into: &initialState)
```

### iCloud sync

`SwiduxCloudKitSync` adds opt-in iCloud sync with a runtime opt-out toggle (`SyncCoordinator`), launch-time entitlement/account detection (`SyncPreflightService` → `SyncStatus`), and a merge-based remote-change observer. Linking this product is the single signal that an app needs the iCloud/CloudKit/Push entitlement family; a local-only app links only `SwiduxPersistence`.

### Companion packages

- [`SwiduxRevenueCatPaywall`](https://github.com/heirloomlogic/SwiduxRevenueCatPaywall) — RevenueCat adapter for `SwiduxPaywall`. Ships `RevenueCatPaywallService` (drop-in `PaywallService`), a mock for previews, and a SwiftUI sheet built on RevenueCatUI.

## Macros

`@Swidux` and `@Slice` eliminate the observer-class boilerplate that would otherwise sit between your value-type state and SwiftUI's `@Observable` requirement.

```swift
// Before — you'd hand-write an @Observable class mirroring AppState plus
// a SwiduxObservable conformance with pack/unpack/restore methods.

// After:
@Swidux
nonisolated struct AppState: Equatable, Sendable {
    var items: EntityStore<Item> = .init()
    @Slice var ui: UIState = .init()
}
```

The macros emit an `AppStateObserver` class and a `SwiduxObservable` extension. `@Slice` ensures composed state slices keep per-property observation. See [Macros Reference](https://heirloomlogic.github.io/Swidux/documentation/swidux/macrosreference).

`SwiduxPersistence` adds `@Persisted` (with the property markers `@Relation`, `@ForeignKey`, `@Inline`, `@Ignored`), which generates a domain entity's SwiftData `@Model` shadow and converters. It operates on entities stored in an `EntityStore` — a different layer than `@Swidux`, which annotates state containers — so the two never apply to the same type.

> **Note for Redux users:** `@Slice` is not Redux Toolkit's `createSlice`. Swidux slices don't own reducers — `@Slice` is a structural marker for nested `@Swidux` properties so SwiftUI gets per-property observation. Apologies for the term overload; we picked it for memorability over literal equivalence.

## Documentation

Full DocC reference at https://heirloomlogic.github.io/Swidux/documentation/swidux/. Starting points by intent:

- **I want to learn** — [Build Your First Swidux App](https://heirloomlogic.github.io/Swidux/documentation/swidux/buildingyourfirstapp)
- **I want to add a paywall / killswitch / parental gate** — the three how-tos linked above
- **I want the API** — [Macros Reference](https://heirloomlogic.github.io/Swidux/documentation/swidux/macrosreference), [EntityStore Guide](https://heirloomlogic.github.io/Swidux/documentation/swidux/entitystoreguide), [Persistence Middleware Guide](https://heirloomlogic.github.io/Swidux/documentation/swidux/persistencemiddlewareguide), [KeyValueStore Guide](https://heirloomlogic.github.io/Swidux/documentation/swidux/keyvaluestoreguide), [Undo / Redo](https://heirloomlogic.github.io/Swidux/documentation/swidux/undoredo)
- **I want to understand the design** — [Architecture Guide](https://heirloomlogic.github.io/Swidux/documentation/swidux/architectureguide), [Plugin Architecture](https://heirloomlogic.github.io/Swidux/documentation/swidux/pluginarchitecture), [Design Principles](https://heirloomlogic.github.io/Swidux/documentation/swidux/designprinciples)
- **I want to write my own plugin** — [Building a Domain Plugin](https://heirloomlogic.github.io/Swidux/documentation/swidux/buildingadomainplugin)

## Installing the agent skill

Swidux ships a companion agent skill, `swidux-ref`, with the architecture rules and copy-pasteable code templates your AI coding assistant needs. It lives in the public [heirloomlogic/skills](https://github.com/heirloomlogic/skills) repo.

**Install (GitHub CLI, recommended):**

```bash
gh skill install heirloomlogic/skills swidux-ref --agent claude-code --scope user
```

`--scope user` installs to `~/.claude/skills/`. Pass `--scope project` to commit it to the current project's `.claude/skills/` so the whole team gets it. Pin a version with `swidux-ref@v1.2.3`. Requires `gh` ≥ v2.90.0.

**Install (skills.sh):**

```bash
npx skillsadd heirloomlogic/skills
```

For Codex, Cursor, Gemini CLI, and other agents — plus a `curl`-only fallback — see the [Agent Skill](https://heirloomlogic.github.io/Swidux/documentation/swidux/agentskill) article.

## Requirements

Swift 6.2+ / Xcode 26+, macOS 15+ / iOS 18+. Strict concurrency (`.swiftLanguageMode(.v6)`).

## License

See [LICENSE](LICENSE) for details.
