# Add a Paywall

Wire the `SwiduxPaywall` plugin into a Swidux app to gate features behind a subscription or lifetime purchase.

## Overview

This guide takes you from a wired Swidux app to a fully gated feature with paywall presentation, entitlement observation, restore, and manage-subscription support. It covers state and action wiring, implementing a `PaywallService`, presenting the sheet, gating a feature, and previewing in pro state.

For an API-level reference of every type and action, see <doc:PluginPaywallReference>. For where domain plugins fit in the dispatch cycle, see <doc:PluginArchitecture>.

## Before you start

This guide assumes:

- You have a Swidux app already wired up — `AppState`, `AppAction`, `AppReducer`, and `AppStore` exist and the store is in the SwiftUI environment. If you're not there yet, follow <doc:GettingStarted> first.
- You have a purchase backend in mind. RevenueCat is the path of least resistance, but vanilla StoreKit or a custom server work just as well — the plugin doesn't care.

## Step 1: Add the dependency

Add the `SwiduxPaywall` product to your app target in `Package.swift`:

```swift
.target(
    name: "MyApp",
    dependencies: [
        "Swidux",
        "SwiduxPaywall",
    ]
)
```

## Step 2: Add state and actions

Add a paywall slice to `AppState` with `@SwiduxNested`, and a paywall case to `AppAction`:

```swift
// AppState.swift
import SwiduxPaywall

@SwiduxState
nonisolated struct AppState: Equatable, Sendable {
    @SwiduxNested var paywall: PaywallState = .init()
    // … other slices
}
```

```swift
// AppAction.swift
import SwiduxPaywall

enum AppAction: Sendable {
    case paywall(PaywallAction)
    // … other cases
}
```

The plugin owns reducing for `.paywall` actions, so the root reducer should fall through:

```swift
// AppReducer.swift
case .paywall:
    return nil
```

## Step 3: Provide a `PaywallService`

The plugin needs a `PaywallService` conformer that talks to your purchase backend. Pick the path that matches your backend.

### Path A: RevenueCat (recommended)

Add the [`SwiduxRevenueCatPaywall`](https://github.com/heirloomlogic/SwiduxRevenueCatPaywall) companion package and use the supplied `RevenueCatPaywallService`. No bridging code on your side.

```swift
.package(url: "https://github.com/heirloomlogic/SwiduxRevenueCatPaywall", from: "1.0.0"),
```

```swift
import SwiduxRevenueCatPaywall

let service = RevenueCatPaywallService()
```

The companion package also ships `SwiduxRevenueCatPaywallUI`, a SwiftUI sheet built on RevenueCatUI that hands purchase results back through the plugin. See its README for configuration (API key, entitlement identifiers).

### Path B: StoreKit or custom backend

For any non-RevenueCat backend, implement `PaywallService` directly. The protocol is small:

```swift
import SwiduxPaywall

struct MyPaywallService: PaywallService {
    func customerInfo() async throws -> EntitlementSnapshot {
        // Fetch the current entitlement once.
        return EntitlementSnapshot()
    }

    func customerInfoStream() -> AsyncStream<EntitlementSnapshot> {
        AsyncStream { continuation in
            // Yield a new snapshot each time the entitlement changes.
            // Call continuation.finish() when the source ends.
        }
    }

    func restorePurchases() async throws -> EntitlementSnapshot {
        // Run a restore against the user's account and return the result.
        return EntitlementSnapshot()
    }
}
```

A vanilla StoreKit conformer iterates `Transaction.currentEntitlements` and listens to `Transaction.updates`; a custom server conformer hits whatever endpoint reports the user's entitlement.

### Previews and tests

Use the built-in `MockPaywallService` for backend-agnostic previews:

```swift
let service = MockPaywallService(isPro: true)
```

If you're on Path A, `SwiduxRevenueCatPaywall` also ships `MockRevenueCatPaywallService` for RevenueCat-flavored previews.

## Step 4: Wire the plugin

Construct and register `PaywallPlugin` inside your `Store.configured()` factory:

```swift
import SwiduxPaywall

let paywallPlugin = PaywallPlugin<AppState, AppAction>(
    state: \.paywall,
    action: AppAction.paywall,
    extractAction: { if case .paywall(let a) = $0 { return a }; return nil },
    service: RevenueCatPaywallService()
)
plugins.register(paywallPlugin)
```

## Step 5: Observe customer info on launch

Start the long-lived entitlement stream once, on the root view:

```swift
struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        RootContent()
            .task { store.send(.paywall(.observeCustomerInfo)) }
    }
}
```

`observeCustomerInfo` returns an effect that lives for the duration of `PaywallService.customerInfoStream()`. Every snapshot the service yields flows through `.customerInfoUpdated` and updates `store.paywall.isPro` / `hasPermanentLicense`.

## Step 6: Present the paywall

Bind a sheet to `store.paywall.isPresented` and dispatch `.paywall(.dismiss)` when it closes:

```swift
.sheet(isPresented: Binding(
    get: { store.paywall.isPresented },
    set: { if !$0 { store.send(.paywall(.dismiss)) } }
)) {
    PaywallSheet()
}
```

Trigger presentation by dispatching `.paywall(.request(reason:))` with a short identifier describing why you're asking. The reason is stored in `store.paywall.requestedReason` so the sheet can tailor its copy.

```swift
store.send(.paywall(.request(reason: "export-pdf")))
```

## Step 7: Gate a feature

Read `PaywallState.isGateSatisfied` before running gated work. If it's `false`, dispatch `.request` instead:

```swift
Button("Export PDF") {
    if store.paywall.isGateSatisfied {
        store.send(.export(.exportPDF))
    } else {
        store.send(.paywall(.request(reason: "export-pdf")))
    }
}
```

## Step 8: Restore purchases

Add a restore button to your paywall sheet. Reflect `store.paywall.isLoading` to disable it while the call is in flight:

```swift
Button("Restore Purchases") {
    store.send(.paywall(.restorePurchases))
}
.disabled(store.paywall.isLoading)
```

On success, the resulting snapshot flows through `.customerInfoUpdated` and updates the gate. On failure, `store.paywall.error` is set.

## Step 9: Manage subscriptions

For an existing subscriber, surface a button that deep-links into the system subscription management page:

```swift
Button("Manage Subscription") {
    store.send(.paywall(.openManageSubscriptions))
}
```

This opens `itms-apps://apps.apple.com/account/subscriptions` via the plugin's `openURL` handler, which routes to the App Store on iOS and Settings on macOS.

## Testing

Use `MockPaywallService` to drive previews and tests into a known entitlement state:

```swift
#Preview("Pro") {
    let store = AppStore.configured(
        paywallService: MockPaywallService(isPro: true)
    )
    return ContentView().environment(store)
}

#Preview("Free") {
    let store = AppStore.configured(
        paywallService: MockPaywallService()
    )
    return ContentView().environment(store)
}
```

Plumb the service through a parameter on your `Store.configured()` factory so previews can override it without touching the live RevenueCat SDK.

## See Also

- <doc:PluginPaywallReference>
- <doc:PluginArchitecture>
