# SwiduxFeatureFlags Reference

API reference for the `SwiduxFeatureFlags` library — typed feature flags, A/B variants, and remote-tunable scalar values backed by a Swidux-defined JSON wire format.

## Overview

`SwiduxFeatureFlags` is a domain plugin that owns a `FeatureFlagsState` slice, fetches a JSON wire format via a provider-agnostic `FeatureFlagsService`, and answers reads against state. Bucketing is a pure hash, so reads are synchronous and work offline.

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

### Schema evolution

Each entry in `flags` decodes on its own. An entry whose `type` the running build doesn't know is skipped, and the rest of the document applies; a read of the skipped flag behaves as if the flag were absent from the config. Each skipped entry is logged at error level to the `swidux` subsystem, `featureflags` category, with the flag key and type public.

An entry with a known type and a malformed body still rejects the whole document, as does an entry with no `type`. A rollout outside 0–100, variant weights that don't sum to 100, or a `value` that isn't a JSON scalar is a publishing error, not a newer schema, so the plugin keeps its last-known-good config.

Two rules keep builds already in the field working as the format grows:

- **A new flag type is additive only when every build reading the endpoint skips unknown types.** Skipping ships in the first release after 1.10.0. Builds on 1.10.0 or earlier reject the whole document on an unknown `type`, so if any are still in the field, serve the new type from a new resource such as `/<appID>/flags-v2`, as the next rule describes. Once every build has the skip, publish on the existing endpoint: a build that predates the type skips that one flag and keeps applying the others. Changing an existing key to a new type looks the same to those builds: the flag reads as absent and takes its Swift default, because each fetch replaces the whole config and no per-flag last-known-good value is kept.
- **Never bump `version` on an endpoint that shipped builds read.** Every build that predates the bump rejects the whole document from then on: installs with a cached config stay on it, and fresh installs get no remote flags. Ship a breaking schema as a new resource, such as `/<appID>/flags-v2`, and keep serving the old one to the builds that read it. The shared `Examples/ConfigWorker` returns 404 for any resource missing from `RESOURCES` in `worker.js`, so add the new resource there.

## Bucketing and identity

`bucket = fmix32(FNV1a(bucketingID + ":" + flagKey)) % 10_000`

A boolean flag is on when `bucket < rollout * 100`. Variant weights scale the same way: with weights `[50, 25, 25]`, buckets `0..<5_000` get the first variant, `5_000..<7_500` the second, and `7_500..<10_000` the third.

- **Stable per `(bucketingID, flagKey)` pair.** Same input always produces the same bucket. Changing the function re-buckets every user, so it changes only in a major release. 2.0.0 replaced the 1.x hash (FNV-1a modulo 100, no finalizer), so upgrading from 1.x re-buckets every user once.
- **Per-flag.** A user isn't always in the "early" group across different flags. Two flags' cohorts are independent at any rollout size: of the users in one flag's 1% canary, about 1% are also in another flag's 1% canary.
- **Identity resolution.** When a `userIDKeyPath` is configured *and* the current user ID is non-nil, that is used. Otherwise the **device ID** is used (the plugin's required `deviceIDKeyPath`). Anonymous users get a stable per-install identity; logged-in users get stable cross-device assignment. A user's variant *can* shift once at login — acceptable for nearly all real use cases.

FNV-1a with murmur3's `fmix32` finalizer was chosen because it's simple and dependency-free. It is not GrowthBook-compatible: GrowthBook hashes the ID and a seed with no separator, over UTF-16, into 1,000 (v1) or 10,000 (v2) buckets, so an app migrating from GrowthBook re-buckets about half of every 50/50 experiment.

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
- **`exposedValues`** *not* persisted. New session = fresh exposure events.

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
store.send(.featureFlags(.recordExposure(of: .checkoutLayout)))
```

Or via the SwiftUI sugar:

```swift
WizardView()
    .recordsExposure(of: .checkoutLayout, store: store, action: AppAction.featureFlags)
```

Pass the typed flag, not its key. The plugin evaluates the exposure through the same path as the read, so the recorded value is the one the user saw:

- A local override the read ignores (the wrong type for the flag) is ignored by the exposure too.
- A remote variant your enum can't parse makes the read return the Swift default, and records **no** exposure. The user was assigned an arm they weren't shown — typically an arm added server-side before the app version that knows it — so counting them in either arm would skew the experiment.
- If the read passed an explicit `bucketingID:`, pass the same one to `recordExposure(of:bucketingID:)` or the modifier.

The plugin records the first exposure of each (flag, value) pair per session and fires the optional `onExposure` callback (passed at plugin init) for it. A reassignment — sign-in switching the bucketing identity, or a refresh changing the rollout — renders a value the flag hasn't reported yet, so it is recorded once and exposure analytics see the treatment the user now has. A value that comes back later in the session (an override toggled off and on, two views bucketing the same flag by different identities) isn't recorded again. Wire the callback to your analytics plugin to forward exposures as events.

The key-only `recordExposure(key:)` is deprecated: without the flag's type it records overrides and remote variants verbatim and always buckets by the default identity.

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

The plugin bounds every fetch with its `fetchTimeout:` init parameter (default 30 seconds). A fetch still running at the deadline is cancelled and reported as `.refreshFailed`, and its result is dropped if it arrives later. That keeps a custom service that never returns from holding `isFetching`, which would otherwise block every later `.refresh` for the session. Keep the value above your service's own timeout so the service's error is the one reported.

### Built-in: `HTTPFeatureFlagsService`

`URLSession` + `JSONDecoder`. Apps host their JSON anywhere — static file on a CDN, Cloudflare Worker, their own server. Zero backend infrastructure required. `Examples/ConfigWorker/` is a runnable shared Worker serving flags + killswitch for a whole portfolio from one URL (`GET /<appID>/flags`).

The URL must be **HTTPS** (`http` is allowed only for `localhost` development servers; anything else is a precondition failure at init). Responses over 1 MB and non-2xx statuses throw, and malformed variant definitions (empty array, negative weights, weights not summing to 100) fail decoding — in every case the plugin keeps its last-known-good cached config.

Third-party adapters (LaunchDarkly, GrowthBook, Statsig) conform to the same protocol without changing the plugin.

### Diagnostics

A failed refresh keeps the current config, so nothing on screen changes. The plugin logs it at error level to the `swidux` subsystem, `featureflags` category, with a summary of the error. When the service is `HTTPFeatureFlagsService`, the line also names its URL, without the query, fragment, or credentials; other services' failures are logged without one. A non-2xx response to `HTTPFeatureFlagsService` names its status, so a wrong URL reads as `HTTP 404`. The plugin remembers only the last failure it logged, in memory: a failure identical to it is skipped until a refresh succeeds, so an outage is logged once per launch as long as the error stays the same, and a different error is logged again. A cancelled refresh isn't logged. `lastFetchError` records every failure either way.

In debug builds, an `HTTPFeatureFlagsService` response that is 2xx and carries `X-Config-Source: default` logs at warning level, `remoteconfig` category. A config worker can send that header when nothing is stored under the requested key and it serves its fallback instead, which usually means the app ID in the URL is wrong. `Examples/ConfigWorker` doesn't send this header.

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

Reads are pure synchronous functions. Observation is per *property* of the slice, not per flag: every read depends on `config` and `localOverrides` (and bucketed reads on the resolved identity), so a view that reads any flag re-renders whenever the config changes — even if the flag it reads is unchanged. A refresh that returns an identical config doesn't notify, because the assignment is equality-checked.

## Action semantics (selected)

`refreshSucceeded(FeatureFlagsConfig, fetchedAt:)` is dispatched for every fetch that succeeds, including one that returns an unchanged config. A `.refresh` that is debounced by `RefreshPolicy.automatic`, or that arrives while a fetch is already in flight, does not fetch and dispatches nothing. Consume config transitions by observing `FeatureFlagsState` or a value derived from it — not by mapping this action. See <doc:PluginArchitecture#Service-Result-Actions-and-Transition-Observation>.
