# SwiduxAnalytics Reference

API reference for the `SwiduxAnalytics` library — provider-agnostic analytics with declarative event mapping, auto-identify, and explicit dispatch for the cases the mapper can't cover.

## Overview

`SwiduxAnalytics` is a domain plugin that observes the dispatch cycle and forwards events to a provider-agnostic `AnalyticsService`. Unlike the gate-style plugins (`SwiduxPaywall`, `SwiduxKillswitch`, `SwiduxParentalGate`), analytics is an **observer**: it watches actions flow by and emits events, but never blocks dispatch.

Two surfaces:

- **Mapper (passive)** — App declares a `(state, action) -> [AnalyticsEvent]` closure once at registration. The plugin runs it in `afterReduce` for every non-analytics action while the user is opted in.
- **`AnalyticsAction` (explicit)** — Screen views, identify/alias/reset, ad-hoc tracks, and opt-out toggling. For the things passive observation can't cover cleanly.

Plus optional **auto-identify**: pass an `AnalyticsIdentity` keypath and the plugin watches userID transitions across dispatches, firing `service.identify` / `service.reset` automatically.

For end-to-end wiring, see <doc:HowToAddAnalytics>. For where this plugin sits in the lifecycle, see <doc:PluginArchitecture>.

## Library target

- Product: `SwiduxAnalytics`
- Import: `import SwiduxAnalytics`

Add the product to your target dependencies in `Package.swift` alongside `Swidux`.

## Provided implementations

The plugin ships with two in-repo conformers, both provider-agnostic and SDK-free:

- `MockAnalyticsService` — silent no-op, for previews and tests.
- `ConsoleAnalyticsService` — logs every call to `os.Logger`. Use this as the default `service:` while the analytics vendor decision is still open: analytics wiring can be developed and QA-tested end to end with no SDK and no vendor commitment. Adopting a real provider later is the usual two-line change in `Store.configured()`.

For production Mixpanel integrations, the [`SwiduxMixpanelAnalytics`](https://github.com/heirloomlogic/SwiduxMixpanelAnalytics) companion package provides:

- `MixpanelAnalyticsService` — an `AnalyticsService` conformer that forwards to the Mixpanel SDK and maps `AnalyticsValue` to native Mixpanel types.
- `MockMixpanelAnalyticsService` — a Mixpanel-flavored mock for previews.

Full API documentation lives in the package's own [DocC reference](https://heirloomlogic.github.io/SwiduxMixpanelAnalytics/documentation/swiduxmixpanelanalytics/).

For other backends (Amplitude, PostHog, Segment, custom), implement `AnalyticsService` directly — see <doc:HowToAddAnalytics> Step 3, Path B.

## Types

### `AnalyticsPlugin<RootState, RootAction>`

`@MainActor` `final class` `SwiduxPlugin` conformer. Owns a slice of root state typed as `AnalyticsState` and an action enum typed as `AnalyticsAction`.

```swift
public init(
    state: WritableKeyPath<RootState, AnalyticsState>,
    action toRootAction: @escaping @Sendable (AnalyticsAction) -> RootAction,
    extractAction: @escaping @Sendable (RootAction) -> AnalyticsAction?,
    service: any AnalyticsService,
    mapper: AnalyticsMapper<RootState, RootAction> = .none,
    identity: AnalyticsIdentity<RootState>? = nil
)
```

The plugin is a `final class` (not a struct) because it tracks pending fire-and-forget service calls so that `flush()` can deterministically await them — same reason `PersistencePlugin` and `UndoPlugin` are classes.

### `AnalyticsState`

`Sendable`, `Equatable` struct. The slice the plugin owns.

```swift
public struct AnalyticsState: Sendable, Equatable {
    public var isOptedOut: Bool
    public var currentScreen: String?
    public internal(set) var lastIdentifiedUserID: String?

    public init(isOptedOut: Bool = false, currentScreen: String? = nil)
}
```

- `isOptedOut` — App-controlled privacy flag. While `true`, mapper events are dropped, explicit `track`/`identify`/`alias` actions become no-ops, and auto-identify is paused.
- `currentScreen` — The most recent screen recorded via `.screenView(_:)`, auto-attached as the `screen` property on subsequent tracked events.
- `lastIdentifiedUserID` — Set by the plugin (read-only from outside the module). Used to detect identity transitions.

### `AnalyticsAction`

```swift
public enum AnalyticsAction: Sendable, Equatable {
    case track(AnalyticsEvent)
    case screenView(String, properties: [String: AnalyticsValue])
    case identify(userID: String, properties: [String: AnalyticsValue])
    case alias(newID: String, previousID: String?)
    case reset
    case setOptedOut(Bool)
}
```

Convenience factories cover the common no-properties cases:

```swift
.screenView("Profile")                    // properties: [:]
.identify(userID: "u1")                   // properties: [:]
.alias(newID: "user-42")                  // previousID: nil
```

### `AnalyticsEvent`

```swift
public struct AnalyticsEvent: Sendable, Equatable {
    public var name: String
    public var properties: [String: AnalyticsValue]

    public init(_ name: String, _ properties: [String: AnalyticsValue] = [:])
}
```

### `AnalyticsValue`

Closed enum keeping the protocol provider-agnostic and `Sendable`. Each service adapter maps these cases to its native property type.

```swift
public enum AnalyticsValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case array([AnalyticsValue])
    case dict([String: AnalyticsValue])
    case null
}
```

Literal conformances keep call-sites clean:

```swift
let props: [String: AnalyticsValue] = [
    "amount": 5,           // .int
    "tier": "pro",         // .string
    "active": true,        // .bool
    "ratio": 0.5,          // .double
    "tags": ["a", "b"],    // .array
]
```

### `AnalyticsMapper<State, Action>`

Wraps the declarative `(state, action) -> [AnalyticsEvent]` closure.

```swift
public struct AnalyticsMapper<State, Action>: Sendable {
    public typealias Map = @Sendable (State, Action) -> [AnalyticsEvent]
    public let map: Map
    public init(_ map: @escaping Map)
    public static var none: AnalyticsMapper { ... }
}
```

Returning an empty array is the no-op case. `.none` is the default mapper for plugins that only use explicit `AnalyticsAction` dispatches.

### `AnalyticsIdentity<State>`

Declarative source-of-truth for the active user's identity.

```swift
public struct AnalyticsIdentity<State>: Sendable {
    public let userID: @Sendable (State) -> String?
    public let userProperties: @Sendable (State) -> [String: AnalyticsValue]

    public init(
        userID: @escaping @Sendable (State) -> String?,
        userProperties: @escaping @Sendable (State) -> [String: AnalyticsValue] = { _ in [:] }
    )

    public init(
        userID keyPath: KeyPath<State, String?> & Sendable,
        userProperties: @escaping @Sendable (State) -> [String: AnalyticsValue] = { _ in [:] }
    )
}
```

The KeyPath convenience init is the typical shape: `AnalyticsIdentity(userID: \.auth.currentUserID)`.

### `AnalyticsService` (protocol)

```swift
public protocol AnalyticsService: Sendable {
    func track(_ event: AnalyticsEvent) async
    func identify(userID: String, properties: [String: AnalyticsValue]) async
    func alias(newID: String, previousID: String?) async
    func reset() async
    func flush() async
}
```

Implementations own batching, retry, network failure handling, and offline queueing. The plugin invokes `track`/`identify`/`alias`/`reset` fire-and-forget; only `flush` is awaited.

### `MockAnalyticsService`

No-op conformer for previews and development.

```swift
public struct MockAnalyticsService: AnalyticsService {
    public init()
    // All methods are no-ops.
}
```

### `ConsoleAnalyticsService`

Logs every `track`/`identify`/`alias`/`reset`/`flush` to `os.Logger`, with a recursive pretty-printer for `AnalyticsValue`. The recommended default before a vendor is chosen.

```swift
public struct ConsoleAnalyticsService: AnalyticsService {
    public init(subsystem: String = "Swidux", category: String = "Analytics")
    // Each call logs one structured line; output visible in
    // the Xcode console and Console.app, quiet in Release.
}
```

## Action semantics

Each case below describes the state mutation the plugin performs and the effect (if any) it returns.

### `track(AnalyticsEvent)`

Returns an effect calling `service.track(event)`, with `currentScreen` auto-attached as the `screen` property if the event doesn't already specify one. Skipped entirely (returns `nil`) when opted out. No state mutation.

### `screenView(String, properties:)`

Sets `currentScreen` to the given name **regardless of opt-out** (the screen state still progresses for when the user opts back in). Returns an effect calling `service.track` with a `"screen_view"` event whose properties include `screen_name` plus any extras. Skipped (returns `nil`) when opted out.

### `identify(userID:, properties:)`

Sets `lastIdentifiedUserID = userID` and returns an effect calling `service.identify`. Skipped when opted out. Use this when the app needs to force identity before the auto-identify keypath would observe the change.

### `alias(newID:, previousID:)`

No state mutation. Returns an effect calling `service.alias`. Skipped when opted out. Call once when an anonymous user signs up to link the anonymous distinct ID to the new user ID.

### `reset`

Sets `lastIdentifiedUserID = nil` and returns an effect calling `service.reset()`. Runs even when opted out — `reset` is by definition a clean-slate operation.

### `setOptedOut(Bool)`

- `setOptedOut(true)` — Sets `isOptedOut = true`, clears `lastIdentifiedUserID`, returns an effect calling `service.reset()` to clear server-side identity.
- `setOptedOut(false)` — Clears the flag without a service call. Auto-identify on the next dispatch will re-establish identity.

## Mapper semantics

The mapper runs in `afterReduce` for every non-analytics action while the user is opted in. The plugin:

1. Skips entirely if the action is an `AnalyticsAction` (handled by `reduce` already, no double-tracking).
2. Skips when `state.isOptedOut`.
3. Calls `mapper.map(state, action)` and tracks each returned event via `service.track`, with `currentScreen` auto-attached as `screen` (unless the event already provides its own `screen`).

Returning an empty array is the no-op case. The mapper closure is allowed to read freely from the post-reducer state — that's deliberately what gets passed in.

## Auto-identify semantics

When configured with an `AnalyticsIdentity`, the plugin re-evaluates both the `userID` and `userProperties` closures each non-analytics dispatch and diffs the pair `(userID, userProperties)` against the last value sent to the service:

- `nil → "u1"` (sign-in): updates `lastIdentifiedUserID` / `lastIdentifiedProperties`, fires `service.identify(userID:"u1", properties:)`.
- `"u1" → "u2"` (account switch): updates both, fires `service.identify(userID:"u2", properties:)`.
- Stable userID, `userProperties` content changed: updates `lastIdentifiedProperties`, fires `service.identify(userID:, properties:)` with the new dictionary.
- `"u1" → nil` (sign-out): clears both, fires `service.reset()`.
- Stable userID and stable `userProperties`: no-op.

`userProperties` is re-evaluated every non-analytics dispatch; dictionary equality decides whether to re-fire `identify`. This keeps derived people-properties (subscription tier, paywall entitlements, feature flags) in sync with state without any explicit `.identify` plumbing.

When opted out, auto-identify is paused: neither `lastIdentifiedUserID` nor `lastIdentifiedProperties` is updated. Opting back in re-establishes identity correctly on the next dispatch.

## Flushing

`AnalyticsPlugin.flush()` awaits any pending fire-and-forget service calls spawned by `afterReduce`, then calls `service.flush()`. Call this on app shutdown to avoid losing in-flight events:

```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .background {
        Task { await store.analyticsPlugin.flush() }
    }
}
```

## Implementing an `AnalyticsService`

The plugin is provider-agnostic. Your conformer is responsible for translating `AnalyticsEvent` and `AnalyticsValue` into whatever the backend SDK expects.

The protocol has five methods, all `async` and non-throwing. Errors are the service's responsibility: log them, queue for retry, drop them — whatever fits your backend's reliability model. The plugin will not see them.

A typical Mixpanel conformer holds a reference to the `Mixpanel.Instance` and translates `AnalyticsValue` → `MixpanelType`. An Amplitude conformer holds an `Amplitude` instance and translates to `[String: Any]`. Either way, the plugin stays the same.

Note what the protocol does **not** require: no opt-out flag (the plugin handles that), no super-property machinery for `currentScreen` (the plugin handles that), and no event batching policy (your call).

## See Also

- <doc:HowToAddAnalytics>
- <doc:PluginArchitecture>
