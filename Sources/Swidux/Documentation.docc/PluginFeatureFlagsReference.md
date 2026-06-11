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
- **Identity resolution.** When a `userIDKeyPath` is configured *and* the current user ID is non-nil, that is used. Otherwise the install ID is used. Anonymous users get a stable per-install identity; logged-in users get stable cross-device assignment. A user's variant *can* shift once at login — acceptable for nearly all real use cases.

FNV-1a was chosen because it's simple, dependency-free, and matches GrowthBook's algorithm so apps migrating from GrowthBook get compatible buckets.

## Evaluation order

For each read, in priority:

1. **Local override present?** Return it.
2. **Flag in remote config?** Evaluate (rollout / variant assignment / value lookup).
3. **Otherwise** return the Swift-side default.

## Persistence

- **Install ID** persisted to `KeyValueStore` on first generation. Read at hydration via `FeatureFlagsState.hydrated(from:defaultConfig:)`.
- **Last-known config** persisted after every successful refresh. Hydrates as fallback before first network success.
- **Local overrides** *not* persisted by default. Restart = clean state.
- **`exposedKeys`** *not* persisted. New session = fresh exposure events.

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
