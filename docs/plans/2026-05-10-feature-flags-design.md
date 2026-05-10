# SwiduxFeatureFlags Design

## Context

Three potential Swidux features were brainstormed: feature flags, A/B testing, and crash reporting. The conclusions:

- **Feature flags** belong as a Swidux plugin. They share the exact shape of existing domain plugins (`KillswitchPlugin`, `PaywallPlugin`): a state slice, an action enum, a provider-agnostic service protocol, and reads against state.
- **A/B testing** belongs in the same plugin as feature flags — modern providers (LaunchDarkly, GrowthBook, Statsig) treat experiments as flags that return variants. Shared fetch/cache/override infrastructure; experimentation just adds variant types and exposure tracking on top.
- **Crash reporting** does not belong in Swidux. It is a process-level concern handled by Crashlytics/Sentry SDKs that install before the store exists and capture state when the runtime is dying. The Swidux-shaped adjacent features (breadcrumbs, identity sync, manual error reports) are already covered by `AnalyticsPlugin`.

This design covers the unified `SwiduxFeatureFlags` plugin only.

## Goals

1. First-class feature flags + A/B variants + remote-tunable scalar values, all from the same plugin and the same wire format.
2. Free out-of-the-box backing service: Swidux defines the JSON wire format and ships an `HTTPFeatureFlagsService` that fetches it from any URL. Apps host the JSON wherever they like (Cloudflare Pages, R2, S3, a Worker, their own server).
3. `FeatureFlagsService` is a protocol so LaunchDarkly / GrowthBook / Statsig adapters can be published as third-party packages without changing the plugin.
4. Type-safe flag keys with Swift-side defaults, mirroring the `KVKey` pattern.
5. Deterministic local evaluation — bucketing is pure and offline-capable. Service only fetches the config; evaluation never round-trips.
6. Per-property observation preserved (flags live in state; views re-render reactively).
7. Same plugin-wiring contract as the other domain plugins (keypath + action lifter + extractor + service).

## Non-goals (v1)

- Targeting rules ("iOS only", "users with property X = Y"). Defer to v2 if real demand emerges. Percentage rollout + variants covers the majority of use cases.
- Per-user force-on lists in the JSON. Use local overrides for QA workflows.
- Built-in retry/backoff. Apps can re-dispatch `.refresh` on a timer if they need it.
- Real-time push updates (SSE/WebSocket). Polling on foreground is sufficient for v1.

## Package layout

New SwiftPM target `SwiduxFeatureFlags`, alongside the existing domain plugin packages.

```
Sources/SwiduxFeatureFlags/
  FeatureFlagsState.swift       // @Swidux state slice
  FeatureFlagsAction.swift      // refresh / override / exposure actions
  FeatureFlagsConfig.swift      // wire-format Codable types
  FeatureFlagsPlugin.swift      // the SwiduxPlugin
  FeatureFlagsService.swift     // protocol + HTTPFeatureFlagsService
  FlagKey.swift                 // typed flag keys (BoolFlag / VariantFlag<E> / ValueFlag<V>)
  Bucketing.swift               // FNV-1a hash + bucket math
  ExposureModifier.swift        // .recordsExposure(of:store:) view modifier
```

## State slice

```swift
@Swidux
public nonisolated struct FeatureFlagsState: Equatable, Sendable {
    public var config: FeatureFlagsConfig = .empty
    public var lastFetchedAt: Date?
    public var lastFetchError: String?       // for debug UI; not surfaced to users
    public var isFetching: Bool = false
    public var localOverrides: [String: FlagValue] = [:]
    public var exposedKeys: Set<String> = []  // session-scoped dedup
    public var installID: UUID                // bucketing identity, set at init
}
```

`installID` is generated on first launch and persisted to `KeyValueStore`. The state slice is hosted in the app's root state via `@Slice var featureFlags: FeatureFlagsState`.

## Actions

```swift
public enum FeatureFlagsAction: Sendable {
    case refresh
    case refreshSucceeded(FeatureFlagsConfig, fetchedAt: Date)
    case refreshFailed(String)
    case setLocalOverride(key: String, value: FlagValue)
    case clearLocalOverride(key: String)
    case clearAllLocalOverrides
    case recordExposure(key: String)
}
```

`FlagValue` is a sum type covering the three supported value types (`Bool` / `String` / scalar `Int`/`Double`/`String` for value flags). Same shape as `AnalyticsValue`.

## Plugin

```swift
@MainActor
public final class FeatureFlagsPlugin<RootState, RootAction>: SwiduxPlugin {
    public init(
        state: WritableKeyPath<RootState, FeatureFlagsState>,
        action toRootAction: @escaping @Sendable (FeatureFlagsAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> FeatureFlagsAction?,
        service: any FeatureFlagsService,
        userIDKeyPath: KeyPath<RootState, String?>? = nil,
        refreshPolicy: RefreshPolicy = .automatic(minInterval: 300),
        defaultConfig: FeatureFlagsConfig? = nil,
        keyValueStore: any KeyValueStore,
        onExposure: (@Sendable (_ key: String, _ value: FlagValue) -> Void)? = nil
    )
}
```

Standard domain-plugin contract: keypath + action lifter + extractor + service. The plugin never assumes root types.

### Lifecycle hooks

| Hook | Behavior |
|---|---|
| `willReduce` | unused |
| `reduce` | routes `FeatureFlagsAction` cases. `.refresh` returns an effect that hits the service, debounced against `lastFetchedAt + minInterval`. `.refreshSucceeded` updates state and persists the new config to `KeyValueStore` via an effect. `.recordExposure` checks `exposedKeys` for dedup and fires `onExposure` for fresh exposures. |
| `afterReduce` | unused |
| `flush` | awaits any in-flight fetch (mirrors `AnalyticsPlugin.flush()`) |

### Refresh policy

```swift
public enum RefreshPolicy: Sendable {
    case manual                                      // never auto-debounces; every .refresh fetches
    case automatic(minInterval: TimeInterval = 300)  // debounce against lastFetchedAt
}
```

The plugin does not subscribe to `UIApplication` notifications. The host app dispatches `.refresh` from `App.scenePhase` transitions; the plugin's debouncing makes this safe to call frequently.

### Plugin registration order

No constraint. Flags don't snapshot state (so they can register after `UndoPlugin`) and don't drain change sets (so they can register before or after `PersistencePlugin`). Recommend grouping with the other domain plugins.

## Wire format

```json
{
  "version": 1,
  "flags": {
    "new_onboarding": {
      "type": "boolean",
      "rollout": 25
    },
    "premium_export": {
      "type": "boolean",
      "rollout": 100
    },
    "checkout_layout": {
      "type": "variant",
      "variants": [
        { "value": "control",     "weight": 50 },
        { "value": "single_page", "weight": 25 },
        { "value": "wizard",      "weight": 25 }
      ]
    },
    "max_free_uploads": {
      "type": "value",
      "value": 5
    }
  }
}
```

**Three flag types:**

- **`boolean`** — on/off with `rollout` percentage (0–100). 0 = off everyone, 100 = on everyone, in between is a stable rollout bucket.
- **`variant`** — string-typed A/B variant with weighted assignment. Weights must sum to 100.
- **`value`** — typed remote-config scalar (`Bool` / `Int` / `Double` / `String`) for tunable constants.

**Rules:**

- `version` at the top. Plugin rejects unknown versions and falls back to cache + Swift-side defaults.
- No per-flag default in JSON — defaults live in Swift at the call site. This keeps defaults type-checked and forces "what if missing?" thinking.
- No targeting rules in v1.
- No per-user force-on lists in the JSON. Use local overrides for QA.

## Typed flag keys

Mirrors the `KVKey` pattern. Host app declares typed keys once; reads are then type-safe and exhaustively switchable.

```swift
extension FlagKey {
    static let newOnboarding   = BoolFlag("new_onboarding")
    static let checkoutLayout  = VariantFlag<CheckoutVariant>("checkout_layout", default: .control)
    static let maxFreeUploads  = ValueFlag<Int>("max_free_uploads", default: 5)
}

enum CheckoutVariant: String { case control, single_page, wizard }
```

`VariantFlag<E: RawRepresentable>` decodes the JSON string into the host's enum at the read site. If the JSON ships a variant the enum doesn't know about, the read returns the Swift-side default — fail-safe by construction.

## Read API

Pure, synchronous reads against state. Safe to call from view bodies.

```swift
store.featureFlags.isEnabled(.newOnboarding)            // Bool
store.featureFlags.variant(of: .checkoutLayout)         // CheckoutVariant
store.featureFlags.value(of: .maxFreeUploads)           // Int
```

Per-property observation works as it does for any other state slice — views re-render only when the flag they read changes.

### Evaluation order

For each read, in priority:

1. **Local override present?** Return it.
2. **Flag in remote config?** Evaluate (rollout / variant assignment / value lookup).
3. **Otherwise** return the Swift-side default.

### Bucketing

`bucket = FNV1a(bucketingID + ":" + flagKey) % 100`

- **FNV-1a** chosen because it's well-known, simple to implement in pure Swift (~10 lines), no dependencies, and matches GrowthBook's algorithm. Same input always produces the same bucket — buckets are stable forever per `(bucketingID, flagKey)` pair.
- Bucketing is per-flag (`flagKey` is part of the hash input) so a user isn't always in the "early" group across different flags.
- Variant assignment uses the same hash, mapped onto cumulative weight ranges.

### `bucketingID` resolution

If `userIDKeyPath` is configured *and* the current user ID is non-nil, use that. Otherwise use `installID`.

This means:
- Anonymous users get a stable per-install identity.
- Logged-in users (when configured) get stable cross-device assignment.
- A user's variant *can* shift once at login (acceptable for nearly all real use cases — documented as an explicit trade-off).

## Persistence

- **`installID`** persisted to `KeyValueStore` on first generation. Read at hydration.
- **Last successful `FeatureFlagsConfig`** persisted to `KeyValueStore` after every `.refreshSucceeded`. Read at hydration as fallback before first network success.
- **Local overrides** *not* persisted by default. Restart = clean state, which is the right behavior for debug ergonomics. Optional `persistOverrides: Bool = false` plugin parameter for QA workflows that need persistent overrides.
- **`exposedKeys`** *not* persisted. New session = fresh exposure events. Matches industry standard (GrowthBook, Statsig).

Hydration helper:

```swift
extension FeatureFlagsState {
    public static func hydrated(
        from store: any KeyValueStore,
        defaultConfig: FeatureFlagsConfig? = nil
    ) -> FeatureFlagsState
}
```

## Error handling

- **Fetch failures** → dispatch `.refreshFailed(message)`. Last-known-good config stays in state. `lastFetchError` set for debug UI; not surfaced to users.
- **Decode failures** (malformed JSON, unknown `version`) → treated as fetch failure. Last-known-good wins.
- **Evaluation failures** are impossible by construction: unknown flag keys → Swift-side default; variant types that don't match → Swift-side default.
- **No retries in v1.** Apps that want retry-with-backoff wrap their service or re-dispatch `.refresh` on a timer.
- **Bundled fallback:** `defaultConfig: FeatureFlagsConfig?` parameter on plugin init lets apps compile a baseline config into the binary. Optional. Most apps won't need it because Swift-side defaults already cover the "flag missing" case.

## Exposure tracking

A/B testing is only analytically valid if you know which users actually saw each variant — bucketing alone is insufficient because the code path branching on the flag might never execute.

### Action surface

```swift
store.send(.featureFlags(.recordExposure(key: "checkout_layout")))
```

The plugin checks `state.exposedKeys`. If the key is already there, no-op. If not, inserts and fires the optional `onExposure` callback (passed at plugin init).

### View modifier surface

Sugar over the action, calls `recordExposure` from `.onAppear`:

```swift
WizardView()
    .recordsExposure(of: .checkoutLayout, store: store)
```

Same dual-surface pattern as `KillswitchBlockerModifier` — action is ground-truth (testable, idiomatic Swidux); modifier is ergonomic.

### Wiring to analytics

The host app passes `onExposure` at plugin init. Typical wiring dispatches an analytics action, which the existing `AnalyticsPlugin` then forwards to its service:

```swift
let flags = FeatureFlagsPlugin<AppState, AppAction>(
    state: \.featureFlags,
    action: AppAction.featureFlags,
    extractAction: { if case .featureFlags(let a) = $0 { return a }; return nil },
    service: HTTPFeatureFlagsService(url: configURL),
    userIDKeyPath: \.session.userID,
    keyValueStore: keyValueStore,
    onExposure: { key, value in
        Task { @MainActor in
            store.send(.analytics(.track(AnalyticsEvent("feature_flag_exposed", [
                "flag_key": .string(key),
                "flag_value": value.analyticsValue
            ]))))
        }
    }
)
```

(Wiring sketched here for clarity; final shape may use a dedicated helper.)

## Service protocol

```swift
public protocol FeatureFlagsService: Sendable {
    func fetch() async throws -> FeatureFlagsConfig
}
```

One method. Caching, hydration, evaluation all live in the plugin so they're identical regardless of backend.

### Built-in: `HTTPFeatureFlagsService`

```swift
public struct HTTPFeatureFlagsService: FeatureFlagsService {
    public init(url: URL, session: URLSession = .shared, decoder: JSONDecoder = .init())
    public func fetch() async throws -> FeatureFlagsConfig
}
```

Just `URLSession` + `JSONDecoder`. Apps host their JSON anywhere — static file on a CDN, Cloudflare Worker, their own server. Zero backend infrastructure required.

### Third-party adapters (out of scope, future work)

`LaunchDarklyFeatureFlagsService`, `GrowthBookFeatureFlagsService`, etc. are protocol conformances anyone can publish as a separate package. Not maintained by Swidux core.

## Testing

- `FeatureFlagsService` is a protocol → tests inject `MockFeatureFlagsService { config }`.
- `KeyValueStore` already has `InMemoryKeyValueStore`.
- Bucketing is pure → property-based tests confirm:
  - Same `(bucketingID, flagKey)` always produces same bucket.
  - Weight distribution matches statistical expectation across N samples.
  - Different flag keys produce independent buckets (user not always in "early" group).
- Plugin tests cover: refresh debouncing, evaluation order (override beats remote beats default), exposure dedup per session, `userIDKeyPath` override behavior, decode failure → last-known-good.
- Swift Testing throughout (`@Test`, `#expect`).
- Counter example app gets a "Feature Flags" demo screen showing all three flag types reading from a static JSON in the bundle.

## Documentation

- DocC catalog in `Sources/SwiduxFeatureFlags/Documentation.docc/` mirroring the other plugin packages.
- Articles: `WiringFeatureFlags`, `WireFormatReference`, `BucketingAndIdentity`, `ExposureTracking`.
- Update the swidux-ref skill with a "Feature flags" entry in the "When to use what" table and an example in `swidux-patterns.md`.

## Open questions deferred to implementation

- Exact name for `FlagValue` sum type (vs. reusing `AnalyticsValue` shape).
- Whether `onExposure` should be a callback or a built-in dispatch helper that takes the analytics keypath.
- Whether `HTTPFeatureFlagsService` should expose a configurable cache policy on the `URLSession`/`URLRequest` (probably yes; default to no HTTP cache so the plugin's own cache is the source of truth).
