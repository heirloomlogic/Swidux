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
    identity: AnalyticsIdentity<RootState>? = nil,
    onConsentChange: (@Sendable (Bool) async -> Void)? = nil
)
```

`onConsentChange` fires on every `.setOptedOut` dispatch with the new opted-out value. Use it to drive a vendor SDK's own consent API — see *Consent* below.

The plugin is a `final class` (not a struct) because it queues service calls off the dispatch path and tracks them so that `flush()` can deterministically await them — same reason `PersistencePlugin` and `UndoPlugin` are classes.

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

Implementations own batching, retry, network failure handling, and offline queueing.

An `identify` implementation that stores a user profile must set each property it is given, leave a key omitted from `properties` at its saved value, and delete a key passed as `.null`. Implementations that store no profile, such as `ConsoleAnalyticsService` and `MockAnalyticsService`, have nothing to merge. Auto-identify passes whatever dictionary `userProperties` returns, so a key that drops out of that dictionary is omitted from the next `identify`, so a conforming implementation leaves it at its saved value; return `.null` for the key to delete it.

Dispatch never waits for the service, but the plugin **serializes** its calls: `track`/`identify`/`alias`/`reset` run one at a time in dispatch order, each starting after the previous one returns (see *Queueing*). A conformer that awaits a network round trip inside `track` therefore delivers one event per round trip, and while a call is stalled (offline, a 60-second request timeout) every later call waits behind it. Enqueue the work and return promptly, as vendor SDKs do; upload from the service's own background queue.

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

Each case below describes the state mutation the plugin performs and the service call it queues. `reduce` returns no effect for any case: the call runs on the plugin's worker (see *Queueing*), and `flush()` is how to wait for it.

### `track(AnalyticsEvent)`

Queues `service.track(event)`, with `currentScreen` auto-attached as the `screen` property if the event doesn't already specify one. Skipped entirely when opted out. No state mutation.

### `screenView(String, properties:)`

Sets `currentScreen` to the given name **regardless of opt-out** (the screen state still progresses for when the user opts back in). Queues `service.track` with a `"screen_view"` event whose properties include `screen_name` plus any extras. Skipped when opted out.

### `identify(userID:, properties:)`

Sets `lastIdentifiedUserID = userID` and queues `service.identify`. Skipped when opted out. Use this when the app needs to force identity before the auto-identify keypath would observe the change — see *Explicit identify and auto-identify* below for how the two interact.

### `alias(newID:, previousID:)`

No state mutation. Queues `service.alias`. Skipped when opted out. Call once when an anonymous user signs up to link the anonymous distinct ID to the new user ID.

### `reset`

Sets `lastIdentifiedUserID = nil` and queues `service.reset()`. Runs even when opted out — `reset` is by definition a clean-slate operation.

### `setOptedOut(Bool)`

- `setOptedOut(true)` — Sets `isOptedOut = true`, clears `lastIdentifiedUserID`, discards every `track`, `screen_view`, `identify` and `alias` call still in the queue, runs `onConsentChange(true)` when a hook is configured, and queues `service.reset()` behind it to clear server-side identity.
- `setOptedOut(false)` — Clears the flag and queues `onConsentChange(false)` when a hook is configured. Auto-identify on the next dispatch will re-establish identity.

## Queueing

Dispatch never waits for the service. Every call the plugin makes — explicit, mapped, and auto-identify — joins one queue that a worker task drains off the main actor, one call at a time, in dispatch order. A `track` that awaits a network round trip holds back every call behind it for the length of the request.

The queue holds at most 1,000 `track` calls (explicit `track`, `screenView`, and mapper events). Queuing one past that drops the oldest queued `track`; nothing reports the drop. `identify`, `alias` and `reset` are never dropped, however many are waiting. Opting out discards every call still in the queue that needs consent — see *Consent*.

The opt-out hook, `onConsentChange(true)`, doesn't join this queue: opt-out hooks run in dispatch order without waiting for service calls, so a stalled service call cannot delay a withdrawal. The worker takes no further call off the queue while an opt-out hook is in flight, so every call still queued when it is dispatched, and every call queued after it, waits for the hook to return. The opt-in hook, `onConsentChange(false)`, does join the queue. It runs after every call queued before it, so an opt-out's `reset` still waiting behind a stalled call reaches the SDK before the SDK opts back in, and calls queued after it wait for it to return. An opt-out that arrives while the opt-in hook is still queued removes it; one that arrives while the hook is running waits for it to finish.

## Consent

Opting out is enforced *plugin-side*: `track`, `screenView`, `identify`, `alias`, the mapper, and auto-identify all return early while `isOptedOut`, so nothing reaches the service. Only `reset` and `flush` still pass through.

That gate stops Swidux-dispatched events. It does not touch the vendor SDK's own consent switch — so an SDK configured to collect automatic events, or one still holding a queue of its own, can keep sending after the user opts out. `AnalyticsService` deliberately stays at five members (consent APIs differ too much between vendors to abstract, and only the app knows which one it is using), so the bridge is the `onConsentChange` closure.

Semantics: it fires on every `.setOptedOut` dispatch with the new value, and on opt-out it runs **before** `service.reset()`, so the SDK receives the withdrawal before the service reset. What the SDK does with uploads it has queued or started remains the adapter's responsibility.

Treat this as required wiring for any vendor with a consent API, not an optional extra: without it, "opted out" means only that Swidux stopped sending. See <doc:HowToAddAnalytics> Step 9 for the wiring.

Keep the user's choice in app storage. Before creating the store, seed `AnalyticsState(isOptedOut:)` from that choice. Then dispatch `.setOptedOut(storedValue)` once from the root view at launch. The dispatch applies the stored value to the vendor SDK even when it matches the plugin's initial state. This keeps the plugin and vendor in step when a vendor starts opted out by default.

Opting out discards the plugin's queued `track`, `screen_view`, `identify` and `alias` calls as the action reduces, so their payloads are released at once; a queued `reset` stays. A call already taken off the queue, whether the service is running it or the worker is about to, is not discarded and may still reach the service after the opt-out. Until the user opts back in, the plugin queues only `reset` calls: one for an explicit `reset` action, and one for every `.setOptedOut(true)` dispatch, including a repeat while already opted out. The hook says nothing about what the vendor SDK does with uploads of its own, and it is not a data-deletion API.

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

`userProperties` is re-evaluated every non-analytics dispatch; dictionary equality decides whether to re-fire `identify`. This sends derived people-properties (subscription tier, paywall entitlements, feature flags) without any explicit `.identify` plumbing. Each call carries the current dictionary; a key you stop returning is omitted, not deleted, so it keeps its last value on the profile unless you return `.null` for it.

When opted out, auto-identify is paused: neither `lastIdentifiedUserID` nor `lastIdentifiedProperties` is updated. Opting back in re-establishes identity correctly on the next dispatch.

### Explicit identify and auto-identify

An explicit `.identify(userID:)` that names a different user than the `AnalyticsIdentity` currently derives overrides the derived identity until the derived `userID` changes:

- Derived `nil` (auth state not landed yet), explicit `"u1"`: later dispatches neither `reset` nor re-identify while the derived ID stays `nil`.
- The derived ID then catches up to `"u1"`: no second `identify`, unless the derived `userProperties` differ from what the explicit call sent — then `identify` fires once with the derived properties.
- From then on the derived ID drives identity as usual: `"u1" → "u2"` fires `identify`, `"u1" → nil` fires `reset`.
- The derived ID moving to any value other than the one it held at the explicit call ends the override the same way, including a move to `nil` (sign-out), which fires `reset`.
- `.reset` and `.setOptedOut(true)` end the override. After opting back in, the derived identity is re-identified on the next dispatch.

An explicit `.identify` naming the same user the identity derives is recorded like an auto-identify, so it suppresses a duplicate call and nothing else.

## Flushing

`AnalyticsPlugin.flush()` waits until every queued service call has run and every consent hook has returned, then calls `service.flush()`. It waits without bound, so on shutdown paths use `flush(timeout:)`, which gives up once the deadline passes (queued work keeps running; the caller just stops waiting). `Store` has no typed accessor for a registered plugin, so keep a reference to the one you registered — see <doc:HowToAddAnalytics> Step 6:

```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .background {
        Task { await analytics.flush(timeout: .seconds(2)) }
    }
}
```

`store.flush()` also reaches the plugin — it flushes every registered plugin in order — but through the unbounded `flush()`. That makes it the right sync point in tests and the wrong one on shutdown.

## Implementing an `AnalyticsService`

The plugin is provider-agnostic. Your conformer is responsible for translating `AnalyticsEvent` and `AnalyticsValue` into whatever the backend SDK expects.

The protocol has five methods, all `async` and non-throwing. Errors are the service's responsibility: log them, queue for retry, drop them — whatever fits your backend's reliability model. The plugin will not see them.

A typical Mixpanel conformer holds a reference to the `Mixpanel.Instance` and translates `AnalyticsValue` → `MixpanelType`. An Amplitude conformer holds an `Amplitude` instance and translates to `[String: Any]`. Either way, the plugin stays the same.

Note what the protocol does **not** require: no opt-out flag (the plugin handles that), no super-property machinery for `currentScreen` (the plugin handles that), and no event batching policy (your call).

## See Also

- <doc:HowToAddAnalytics>
- <doc:PluginArchitecture>
