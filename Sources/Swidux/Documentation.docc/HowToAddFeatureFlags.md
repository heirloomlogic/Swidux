# Add Feature Flags

Wire the `SwiduxFeatureFlags` plugin into a Swidux app for typed feature flags, A/B variants, and remote-tunable scalar values from a single JSON config.

## Overview

`SwiduxFeatureFlags` is a domain plugin that owns a `FeatureFlagsState` slice, fetches a Swidux-defined JSON wire format via a provider-agnostic `FeatureFlagsService`, and answers reads against state. Bucketing is pure FNV-1a — same input always produces the same bucket, no network round-trip per read. Local overrides give QA a one-action toggle that wins over remote evaluation.

For an API-level reference, see <doc:PluginFeatureFlagsReference>. For where domain plugins fit in the dispatch cycle, see <doc:PluginArchitecture>.

## Before you start

This guide assumes you have a Swidux app already wired up — `AppState`, `AppAction`, `AppReducer`, and `AppStore` exist and the store is in the SwiftUI environment. If you're not there yet, follow <doc:GettingStarted> first.

You also need somewhere to host a JSON file. Any URL works — Cloudflare Pages, R2, S3, a Worker, your own backend. The plugin doesn't care. `Examples/ConfigWorker/` is a runnable Cloudflare Worker that serves feature-flag *and* killswitch config for every app in a portfolio from one URL and one KV namespace, keyed `GET /<appID>/<resource>` — point this plugin at `https://<host>/<appID>/flags`.

## Step 1: Add the dependency

Add the `SwiduxFeatureFlags` product to your app target in `Package.swift`:

```swift
.target(
    name: "MyApp",
    dependencies: [
        "Swidux",
        "SwiduxFeatureFlags",
    ]
)
```

## Step 2: Add a state slice and action case

In `AppState.swift`:

```swift
import SwiduxFeatureFlags

@Swidux
nonisolated struct AppState: Equatable, Sendable {
    @Slice var featureFlags: FeatureFlagsState = .init()
    // ... your other slices
}
```

In `AppAction.swift`:

```swift
enum AppAction: Sendable {
    case featureFlags(FeatureFlagsAction)
    // ... your other cases
}
```

> Tip: `import SwiduxFeatureFlags` is needed in *every* file that touches `store.featureFlags.*` or `FeatureFlagsAction` — including views that read flags for display. `@_exported import Swidux` re-exports core Swidux only, not plugin modules. See <doc:PluginArchitecture>.

## Step 3: Hydrate state and register the plugin

At app launch, mint a stable per-install **device ID** (Keychain-backed so it survives reinstall — this is the bucketing identity), hydrate state from your `KeyValueStore` (so the last-known-good config survives cold launches), then register the plugin. Add `var deviceID: String = ""` to `AppState` and point `deviceIDKeyPath` at it:

```swift
let kv = UserDefaultsKeyValueStore()                       // flags config cache

// Stable bucketing identity — Keychain so it survives reinstall, and shared
// with analytics: AnalyticsIdentity(userID: \.deviceID, …).
let deviceID = KeychainKeyValueStore(service: "com.example.app").deviceIdentity()

let initial = AppState(
    featureFlags: .hydrated(from: kv, deviceID: deviceID),
    deviceID: deviceID
)

let store = Store(initialState: initial, reducer: AppReducer())

// With the Examples/ConfigWorker setup this is the shared portfolio URL:
// "https://<host>/<appID>/flags". Any URL returning FeatureFlagsConfig works.
let configURL = URL(static: "https://<host>/<appID>/flags")

let flags = FeatureFlagsPlugin<AppState, AppAction>(
    state: \.featureFlags,
    action: AppAction.featureFlags,
    extractAction: { if case .featureFlags(let a) = $0 { return a } else { return nil } },
    service: HTTPFeatureFlagsService(url: configURL),
    deviceIDKeyPath: \.deviceID,
    keyValueStore: kv
)
store.register(plugin: flags)
```

## Step 4: Declare typed flag keys

Declare each flag once on a namespace so reads are type-safe:

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

## Step 5: Read flags from views

```swift
if store.featureFlags.isEnabled(.newOnboarding) {
    NewOnboardingView()
}

let layout = store.featureFlags.variant(of: .checkoutLayout)
let cap = store.featureFlags.value(of: .maxFreeUploads)
```

## Step 6: Refresh on foreground

The plugin debounces `.refresh` against the configured `RefreshPolicy`, so it's safe to dispatch on every `scenePhase` transition:

```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .active { store.send(.featureFlags(.refresh)) }
}
```

## Step 7: Guard against forever flags

Give every flag a required owner and expiry, and add one CI test that fails when a flag outlives its expiry. Declare a manifest alongside the typed keys — the factory `owner`/`expires` parameters are non-optional, and the keys are single-sourced from the flag declarations:

```swift
enum FlagManifest {
    static let all: [FlagDescriptor] = [
        .bool(.newOnboarding, owner: "growth",
              expires: Date(timeIntervalSince1970: 1_788_000_000), purpose: "New onboarding flow"),
        .variant(.checkoutLayout, owner: "checkout",
                 expires: Date(timeIntervalSince1970: 1_785_000_000), purpose: "Checkout A/B"),
        .value(.maxFreeUploads, owner: "platform",
               expires: Date(timeIntervalSince1970: 1_785_000_000), purpose: "Free upload cap"),
    ]
}

@Test func noForeverFlags() {
    let report = FlagGovernance.expirationReport(FlagManifest.all)
    #expect(report == nil, "\(report ?? "")")   // failure names each expired flag + owner
}
```

This is a pure compile-time / test concern — no wire-format change and no effect on runtime evaluation.

For wire format, bucketing, exposure tracking, and governance details, see <doc:PluginFeatureFlagsReference>.
