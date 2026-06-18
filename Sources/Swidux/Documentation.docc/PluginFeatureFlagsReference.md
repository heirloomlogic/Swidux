# SwiduxFeatureFlags Reference

API reference for the `SwiduxFeatureFlags` library — typed feature flags, A/B variants, and remote-tunable scalar values backed by a Swidux-defined JSON wire format.

## Overview

`SwiduxFeatureFlags` is a domain plugin that owns a `FeatureFlagsState` slice, fetches a JSON wire format via a provider-agnostic `FeatureFlagsService`, and answers reads against state. Bucketing is pure FNV-1a so reads are synchronous and offline-capable.

Three flag types from one wire format:

- **boolean** — on/off with rollout percentage (0–100).
- **variant** — string-typed weighted variants for A/B tests.
- **value** — typed remote-tunable scalar (`Bool` / `Int` / `Double` / `String`).

For end-to-end wiring, see <doc:HowToAddFeatureFlags>.

## Library target

- Product: `SwiduxFeatureFlags`
- Import: `import SwiduxFeatureFlags`

## Wire format

```json
{
  "version": 1,
  "flags": {
    "new_onboarding": { "type": "boolean", "rollout": 25 },
    "checkout_layout": {
      "type": "variant",
      "variants": [
        { "value": "control", "weight": 50 },
        { "value": "treatment", "weight": 50 }
      ]
    },
    "max_free_uploads": { "type": "value", "value": 5 }
  }
}
```

The plugin rejects unknown `version` values and falls back to the last-known-good cache. Defaults always live in Swift at the call site — this keeps them type-checked and forces "what if missing?" thinking.

## Bucketing and identity

`bucket = FNV1a(bucketingID + ":" + flagKey) % 100`

- **Stable per `(bucketingID, flagKey)` pair forever.** Same input always produces the same bucket.
- **Per-flag.** A user isn't always in the "early" group across different flags.
- **Identity resolution.** When a `userIDKeyPath` is configured *and* the current user ID is non-nil, that is used. Otherwise the **device ID** is used (the plugin's required `deviceIDKeyPath`). Anonymous users get a stable per-install identity; logged-in users get stable cross-device assignment. A user's variant *can* shift once at login — acceptable for nearly all real use cases.

FNV-1a was chosen because it's simple, dependency-free, and matches GrowthBook's algorithm so apps migrating from GrowthBook get compatible buckets.

### The device ID must be stable across reinstall

Bucketing is only stable if the fallback identity is. The plugin takes a non-optional `deviceIDKeyPath: KeyPath<State, String>` into your `AppState`, so the *app* owns the identity and the *same* value can drive analytics (`AnalyticsIdentity(userID: \.deviceID, …)`) — one identity, so A/B exposure correlates with the user analytics reports against.

Mint it once at launch with the shared core helper, backed by the Keychain so it survives reinstall, and seed it into the slice via `hydrated(from:deviceID:)`:

```swift
// In Store.configured()
let deviceID = KeychainKeyValueStore(service: "com.example.app").deviceIdentity()

let plugin = FeatureFlagsPlugin<AppState, AppAction>(
    state: \.featureFlags, action: AppAction.featureFlags, extractAction: { … },
    service: service,
    deviceIDKeyPath: \.deviceID,          // app-owned, Keychain-backed
    userIDKeyPath: \.auth.currentUserID,  // optional; authed identity wins when set
    keyValueStore: kv
)

let initial = AppState(
    featureFlags: .hydrated(from: kv, deviceID: deviceID),
    deviceID: deviceID
)
```

A `UserDefaults`-backed identity regenerates on reinstall (QA ad-hoc builds, test installs), which silently re-buckets users and breaks A/B assignment — use `KeychainKeyValueStore` for the identity. The flags *config cache* can still live in a lighter store.

## Evaluation order

For each read, in priority:

1. **Local override present?** Return it.
2. **Flag in remote config?** Evaluate (rollout / variant assignment / value lookup).
3. **Otherwise** return the Swift-side default.

## Persistence

- **Device ID** is app-owned and minted once via `KeyValueStore.deviceIdentity()` (Keychain-backed). Seeded into the slice at `FeatureFlagsState.hydrated(from:deviceID:)` and kept in sync from `deviceIDKeyPath`. The plugin no longer mints its own bucketing identity.
- **Last-known config** persisted after every successful refresh. Hydrates as fallback before first network success.
- **Local overrides** *not* persisted by default. Restart = clean state.
- **`exposedKeys`** *not* persisted. New session = fresh exposure events.

## Governance: no forever flags

Owner and expiry are **required** metadata for every flag, enforced by a single unit test rather than the wire format (the JSON stays dumb and fail-open). Declare a manifest with the type-erasing factories — `owner` and `expires` are non-optional, so a flag can't be registered without them — and the keys are single-sourced from the typed flag declarations:

```swift
enum FlagManifest {
    static let all: [FlagDescriptor] = [
        .bool(.newOnboarding, owner: "growth",
              expires: Date(timeIntervalSince1970: 1_788_000_000), purpose: "New onboarding flow"),
        .variant(.checkoutLayout, owner: "checkout",
                 expires: Date(timeIntervalSince1970: 1_785_000_000), purpose: "Checkout A/B"),
    ]
}

@Test func noForeverFlags() {
    let report = FlagGovernance.expirationReport(FlagManifest.all)
    #expect(report == nil, "\(report ?? "")")   // failure names each expired flag + owner
}
```

When a flag passes its expiry, the test fails and the report names the flag, its owner, and how long it's been expired — so a stale flag gets retired instead of living forever. This has no effect on runtime evaluation.

> The manifest is the single declaration site, so a typed flag key never added to it escapes governance. Closing that gap fully would need a macro; until then, convention plus code review covers it.

## Exposure tracking

A/B testing is only analytically valid if you know which users actually saw each variant — bucketing alone is insufficient because the code path branching on the flag might never execute.

```swift
store.send(.featureFlags(.recordExposure(key: "checkout_layout")))
```

Or via the SwiftUI sugar:

```swift
WizardView()
    .recordsExposure(of: .checkoutLayout, store: store, action: AppAction.featureFlags)
```

The plugin dedupes per session and fires the optional `onExposure` callback (passed at plugin init). Wire that callback to your analytics plugin to forward exposures as events.

## Refresh policy

```swift
public enum RefreshPolicy: Sendable {
    case manual                                      // every .refresh fetches
    case automatic(minInterval: TimeInterval)        // debounce; default 300s
}
```

Apps dispatch `.refresh` from `App.scenePhase` transitions; the plugin's debouncing makes this safe to call frequently. The plugin does not subscribe to `UIApplication` notifications — wiring stays in the host app.

## Service protocol

```swift
public protocol FeatureFlagsService: Sendable {
    func fetch() async throws -> FeatureFlagsConfig
}
```

One method. Caching, hydration, evaluation all live in the plugin.

### Built-in: `HTTPFeatureFlagsService`

`URLSession` + `JSONDecoder`. Apps host their JSON anywhere — static file on a CDN, Cloudflare Worker, their own server. Zero backend infrastructure required. `Examples/ConfigWorker/` is a runnable shared Worker serving flags + killswitch for a whole portfolio from one URL (`GET /<appID>/flags`).

The URL must be **HTTPS** (`http` is allowed only for `localhost` development servers; anything else is a precondition failure at init). Responses over 1 MB and non-2xx statuses throw, and malformed variant definitions (empty array, negative weights, weights not summing to 100) fail decoding — in every case the plugin keeps its last-known-good cached config.

Third-party adapters (LaunchDarkly, GrowthBook, Statsig) conform to the same protocol without changing the plugin.

## Typed flag keys

```swift
public struct BoolFlag: Sendable, Hashable
public struct VariantFlag<Variant: RawRepresentable & Sendable> where Variant.RawValue == String
public struct ValueFlag<Value: Sendable>
```

Read API on `FeatureFlagsState`:

```swift
state.isEnabled(.newOnboarding, default: false)
state.variant(of: .checkoutLayout)
state.value(of: .maxFreeUploads)
```

Reads are pure synchronous functions. Per-property observation works as it does for any other state slice — views re-render only when the flag they read changes.

## Action semantics (selected)

`refreshSucceeded(FeatureFlagsConfig, fetchedAt:)` is dispatched on every `.refresh` (including debounced refreshes that return an unchanged config). Consume config transitions by observing `FeatureFlagsState` or a value derived from it — not by mapping this action. See <doc:PluginArchitecture#Service-Result-Actions-and-Transition-Observation>.
