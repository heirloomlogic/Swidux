# Add Analytics

Wire the `SwiduxAnalytics` plugin into a Swidux app for centralized event tracking with declarative event mapping and auto-identify.

## Overview

This guide takes you from a wired Swidux app to fully-tracked user behavior with screen views, action-driven events, identity management, opt-out support, and shutdown flushing. It covers state and action wiring, implementing an `AnalyticsService`, declaring an event mapper, configuring auto-identify, and flushing on app background.

For an API-level reference of every type and action, see <doc:PluginAnalyticsReference>. For where domain plugins fit in the dispatch cycle, see <doc:PluginArchitecture>.

## Before you start

This guide assumes:

- You have a Swidux app already wired up — `AppState`, `AppAction`, `AppReducer`, and `AppStore` exist and the store is in the SwiftUI environment. If you're not there yet, follow <doc:GettingStarted> first.
- You have an analytics backend in mind. Mixpanel is the path of least resistance via the `SwiduxMixpanelAnalytics` companion package, but Amplitude, PostHog, Segment, or a custom backend work just as well — the plugin doesn't care.

## Step 1: Add the dependency

Add the `SwiduxAnalytics` product to your app target in `Package.swift`:

```swift
.target(
    name: "MyApp",
    dependencies: [
        "Swidux",
        "SwiduxAnalytics",
    ]
)
```

## Step 2: Add state and actions

Add an analytics slice to `AppState` with `@Slice`, and an analytics case to `AppAction`:

```swift
// AppState.swift
import SwiduxAnalytics

@Swidux
nonisolated struct AppState: Equatable, Sendable {
    @Slice var analytics: AnalyticsState = .init()
    // … other slices
}
```

```swift
// AppAction.swift
import SwiduxAnalytics

enum AppAction: Sendable {
    case analytics(AnalyticsAction)
    // … other cases
}
```

> Tip: `import SwiduxAnalytics` is needed in *every* file that touches `store.analytics.*` or `AnalyticsAction` — including views that read the slice for display. `@_exported import Swidux` re-exports core Swidux only, not plugin modules. See <doc:PluginArchitecture>.

The plugin owns reducing for `.analytics` actions, so the root reducer should fall through:

```swift
// AppReducer.swift
case .analytics:
    return nil
```

## Step 3: Provide an `AnalyticsService`

The plugin needs an `AnalyticsService` conformer that talks to your analytics backend. Pick the path that matches your backend.

### Path A: Mixpanel (recommended)

Add the [`SwiduxMixpanelAnalytics`](https://github.com/heirloomlogic/SwiduxMixpanelAnalytics) companion package and use the supplied `MixpanelAnalyticsService`. No bridging code on your side.

```swift
.package(url: "https://github.com/heirloomlogic/SwiduxMixpanelAnalytics", from: "1.0.0"),
```

```swift
import SwiduxMixpanelAnalytics

let service = MixpanelAnalyticsService(token: "your-mixpanel-token")
```

See the package's [DocC reference](https://heirloomlogic.github.io/SwiduxMixpanelAnalytics/documentation/swiduxmixpanelanalytics/) for configuration details.

### Path B: Amplitude / PostHog / Segment / custom backend

For any non-Mixpanel backend, implement `AnalyticsService` directly. The protocol is small:

```swift
import SwiduxAnalytics

struct MyAnalyticsService: AnalyticsService {
    func track(_ event: AnalyticsEvent) async {
        // Forward event.name + event.properties to your SDK.
    }

    func identify(userID: String, properties: [String: AnalyticsValue]) async {
        // Set the active user and people properties.
    }

    func alias(newID: String, previousID: String?) async {
        // Link an anonymous distinct ID to a known user ID.
    }

    func reset() async {
        // Clear local identity (logout). Subsequent events should be anonymous.
    }

    func flush() async {
        // Drain in-flight buffers (called by the plugin on app shutdown).
    }
}
```

Translate `AnalyticsValue` cases (`.string`, `.int`, `.double`, `.bool`, `.date`, `.array`, `.dict`, `.null`) into whatever your SDK takes. The mapping is mechanical: each case has an obvious target type.

### Previews and tests

Use the built-in `MockAnalyticsService` for backend-agnostic previews:

```swift
let service = MockAnalyticsService()
```

If you're on Path A, `SwiduxMixpanelAnalytics` ships `MockMixpanelAnalyticsService` for Mixpanel-flavored previews.

## Step 4: Declare an event mapper

The mapper is where you decide which actions become tracked events and what properties they carry. It runs in `afterReduce` for every non-analytics action while the user is opted in.

```swift
import SwiduxAnalytics

let mapper = AnalyticsMapper<AppState, AppAction> { state, action in
    switch action {
    case .counter(.increment(let n)):
        return [AnalyticsEvent("counter_added", ["amount": .int(n)])]

    case .paywall(.request(let reason)):
        return [AnalyticsEvent("paywall_requested", ["reason": .string(reason)])]

    case .paywall(.customerInfoUpdated(let snapshot)) where snapshot.isPro:
        return [AnalyticsEvent("subscription_started")]

    default:
        return []
    }
}
```

A single action can produce zero, one, or several events. The mapper closure is allowed to read freely from `state` — that's deliberately what gets passed in, post-reducer.

## Step 5: Configure auto-identify

If your app has a stable userID source (e.g. an `auth.currentUserID` slice), let the plugin watch it. The plugin auto-fires `identify` on transitions and `reset` on sign-out, with no app-level plumbing.

```swift
let identity = AnalyticsIdentity<AppState>(
    userID: \.auth.currentUserID,
    userProperties: { state in
        [
            "subscription_tier": state.paywall.isPro ? "pro" : "free",
            "signup_date": state.auth.signupDate.map(AnalyticsValue.date) ?? .null,
        ]
    }
)
```

`userProperties` is re-evaluated each non-analytics dispatch. The plugin re-fires `service.identify` whenever the returned dictionary changes — so derived people-properties (subscription tier, paywall entitlements, feature flags, A/B variants) stay in sync with state without any explicit `.identify` plumbing.

## Step 6: Wire the plugin

Construct and register `AnalyticsPlugin` inside your `Store.configured()` factory:

```swift
import SwiduxAnalytics

let analyticsPlugin = AnalyticsPlugin<AppState, AppAction>(
    state: \.analytics,
    action: AppAction.analytics,
    extractAction: { if case .analytics(let a) = $0 { return a }; return nil },
    service: MixpanelAnalyticsService(token: "..."),
    mapper: mapper,
    identity: identity
)
plugins.register(analyticsPlugin)
```

## Step 7: Track screen views

Dispatch `.analytics(.screenView(_:))` from your view's `.onAppear` (or equivalent navigation hook). The plugin updates `state.analytics.currentScreen` and emits a `screen_view` event with `screen_name` plus any extra properties.

```swift
struct ProfileView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form { /* … */ }
            .onAppear { store.send(.analytics(.screenView("Profile"))) }
    }
}
```

Subsequent mapper-emitted events are auto-enriched with `screen: "Profile"` until the next `screenView` dispatch — useful for understanding *where* an action originated without manually passing context through every event.

## Step 8: Track ad-hoc events

For events that don't map cleanly from a domain action, dispatch `.analytics(.track(_:))`:

```swift
Button("Share") {
    store.send(.analytics(.track(
        AnalyticsEvent("share_tapped", ["destination": .string("twitter")])
    )))
}
```

This bypasses the mapper but still gets `currentScreen` auto-attached.

## Step 9: Handle opt-out

Surface a privacy toggle that dispatches `.analytics(.setOptedOut(_:))`:

```swift
Toggle("Share usage analytics", isOn: Binding(
    get: { !store.analytics.isOptedOut },
    set: { store.send(.analytics(.setOptedOut(!$0))) }
))
```

When `setOptedOut(true)` fires, the plugin clears `lastIdentifiedUserID` and calls `service.reset()` to clear server-side identity. While opted out, all tracking is dropped and auto-identify is paused. Opting back in re-identifies the user automatically on the next dispatch.

## Step 10: Flush on app shutdown

Call `flush()` when the app moves to the background or terminates so in-flight events aren't lost:

```swift
@main
struct MyApp: App {
    @State private var store = AppStore.configured()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await store.analyticsPlugin.flush() }
            }
        }
    }
}
```

`flush()` awaits any pending fire-and-forget service calls the plugin spawned, then calls `service.flush()` to drain the SDK's own buffers.

## Testing

Use a recording `AnalyticsService` to verify your mapper and explicit dispatches in tests:

```swift
import Testing
@testable import SwiduxAnalytics

actor RecordingAnalyticsService: AnalyticsService {
    private(set) var events: [AnalyticsEvent] = []
    func track(_ event: AnalyticsEvent) async { events.append(event) }
    func identify(userID: String, properties: [String: AnalyticsValue]) async {}
    func alias(newID: String, previousID: String?) async {}
    func reset() async {}
    func flush() async {}
}

@Test func incrementTracks() async {
    let service = RecordingAnalyticsService()
    let store = AppStore.configured(analyticsService: service)

    store.send(.counter(.increment(5)))
    await store.analyticsPlugin.flush()

    let events = await service.events
    #expect(events.first?.name == "counter_added")
    #expect(events.first?.properties["amount"] == .int(5))
}
```

`flush()` is the deterministic sync point — it awaits all pending tracking tasks before returning, so post-flush assertions are stable.

Plumb the service through a parameter on your `Store.configured()` factory so previews and tests can override it without touching the live SDK.

## See Also

- <doc:PluginAnalyticsReference>
- <doc:PluginArchitecture>
