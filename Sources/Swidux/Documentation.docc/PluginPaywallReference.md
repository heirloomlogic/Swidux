# SwiduxPaywall Reference

API reference for the `SwiduxPaywall` library — paywall presentation, entitlement observation, and purchase orchestration.

## Overview

`SwiduxPaywall` is a domain plugin that owns the paywall slice of your app's state and routes paywall actions through the Swidux dispatch cycle. It is provider-agnostic: the plugin knows nothing about RevenueCat, StoreKit, products, prices, or purchase results. You supply a `PaywallService` conformer that talks to whichever purchase backend you use, and the plugin manages presentation state, async progress, and entitlement transitions.

For end-to-end wiring, see <doc:HowToAddAPaywall>. For where this plugin sits in the lifecycle, see <doc:PluginArchitecture>.

## Library target

- Product: `SwiduxPaywall`
- Import: `import SwiduxPaywall`

Add the product to your target dependencies in `Package.swift` alongside `Swidux`.

## Provided implementations

The plugin ships with two in-repo conformers, both provider-agnostic and SDK-free:

- `MockPaywallService` — fixed snapshot, stream finishes immediately; for previews and tests.
- `SimulatedPaywallService` — a stateful, fully driveable service. Paired with the `SwiduxDevPaywallUI` debug sheet, it lets a developer or QA tester grant Pro/Trial/Permanent, restore, and simulate failure/latency — all flowing through the real plugin pipeline, with no SDK and no vendor commitment. Use it as the `service:` while the paywall vendor decision is still open.

For production RevenueCat integrations, the [`SwiduxRevenueCatPaywall`](https://github.com/heirloomlogic/SwiduxRevenueCatPaywall) companion package provides:

- `RevenueCatPaywallService` — a `PaywallService` conformer that bridges RevenueCat's `CustomerInfo` stream and `restorePurchases()` API.
- `MockRevenueCatPaywallService` — a RevenueCat-flavored mock for previews.
- `SwiduxRevenueCatPaywallUI` — a SwiftUI sheet built on RevenueCatUI that hands purchase results back through the plugin.

Full API documentation lives in the package's own [DocC reference](https://heirloomlogic.github.io/SwiduxRevenueCatPaywall/documentation/swiduxrevenuecatpaywall/).

For other backends (StoreKit, custom server), implement `PaywallService` directly — see <doc:HowToAddAPaywall> Step 3, Path B.

### Resilient last-known-good decorator

`ResilientPaywallService` wraps any `PaywallService` so a transient failure to read entitlements at cold launch never presents a previously-seen paid user as free. It retries with backoff, then falls back to a last-known-good snapshot persisted through an injected `KeyValueStore`. Because that cache vouches for a paid entitlement while offline, back it with `KeychainKeyValueStore` — not `UserDefaults`, whose plist a user can edit or restore from a doctored backup:

```swift
let resilient = ResilientPaywallService(
    base: paywallService,
    store: KeychainKeyValueStore(service: "com.example.myapp")
)
```

Feed the wrapped instance to both `PaywallPlugin(..., service:)` and any app-side entitlement reader. The live provider stays authoritative: any successful snapshot overwrites the cache. See the type's own documentation for the staleness policy and threat model.

## Types

### `PaywallPlugin<RootState, RootAction>`

`@MainActor` `SwiduxPlugin` conformer. Owns a slice of root state typed as `PaywallState` and an action enum typed as `PaywallAction`.

```swift
public init(
    state: WritableKeyPath<RootState, PaywallState>,
    action toRootAction: @escaping @Sendable (PaywallAction) -> RootAction,
    extractAction: @escaping @Sendable (RootAction) -> PaywallAction?,
    service: any PaywallService,
    openURL: @escaping @Sendable (URL) async -> Void = { /* default */ }
)
```

The default `openURL` handler calls `UIApplication.shared.open` on UIKit and `NSWorkspace.shared.open` on AppKit. Override it for testing or for non-standard environments.

### `PaywallState`

`Sendable`, `Equatable` struct. The slice the plugin owns.

```swift
public struct PaywallState: Sendable, Equatable {
    public var isPro: Bool
    public var hasPermanentLicense: Bool
    public var isPresented: Bool
    public var requestedReason: String?
    public var isLoading: Bool
    public var error: String?
    public var isCustomerCenterPresented: Bool
    public var isObservingCustomerInfo: Bool

    public init(
        isPro: Bool = false,
        hasPermanentLicense: Bool = false,
        isPresented: Bool = false,
        requestedReason: String? = nil,
        isLoading: Bool = false,
        error: String? = nil,
        isCustomerCenterPresented: Bool = false,
        isObservingCustomerInfo: Bool = false
    )

    public var isGateSatisfied: Bool { isPro || hasPermanentLicense }
}
```

`isGateSatisfied` is the single read your feature code should consult before running gated work. It is `true` when the user holds an active pro subscription or a permanent license.

### `PaywallAction`

```swift
public enum PaywallAction: Sendable {
    case request(reason: String)
    case dismiss
    case observeCustomerInfo
    case refreshCustomerInfo
    case customerInfoUpdated(EntitlementSnapshot)
    case refreshFailed(String)
    case restorePurchases
    case presentCustomerCenter
    case dismissCustomerCenter
    case openManageSubscriptions
}
```

### `EntitlementSnapshot`

Provider-agnostic value the service emits to describe the user's current entitlement.

```swift
public struct EntitlementSnapshot: Sendable, Equatable {
    public let isPro: Bool
    public let hasPermanentLicense: Bool

    public init(isPro: Bool = false, hasPermanentLicense: Bool = false)
}
```

### `PaywallService` (protocol)

```swift
public protocol PaywallService: Sendable {
    func customerInfo() async throws -> EntitlementSnapshot
    func customerInfoStream() -> AsyncStream<EntitlementSnapshot>
    func restorePurchases() async throws -> EntitlementSnapshot
}
```

### `MockPaywallService`

Test/preview conformer that returns a fixed snapshot. Its stream finishes immediately.

```swift
public struct MockPaywallService: PaywallService {
    public init(isPro: Bool = false, hasPermanentLicense: Bool = false)
    public func customerInfo() async throws -> EntitlementSnapshot
    public func customerInfoStream() -> AsyncStream<EntitlementSnapshot>
    public func restorePurchases() async throws -> EntitlementSnapshot
}
```

### `SimulatedPaywallService`

Stateful `actor` conformer for development and QA. Holds the current entitlement and multicasts changes through `customerInfoStream()`, so simulated grants survive a later `refreshCustomerInfo`/`restorePurchases` exactly as a real service would.

```swift
public actor SimulatedPaywallService: PaywallService {
    public init(
        isPro: Bool = false,
        hasPermanentLicense: Bool = false,
        subsystem: String = "Swidux",
        category: String = "Paywall"
    )

    // PaywallService: customerInfo / customerInfoStream / restorePurchases

    // Simulation surface (not part of PaywallService — driven by the dev UI):
    public func grantPro()
    public func grantTrial()
    public func grantPermanentLicense()
    public func setFree()
    public func setRestoreShouldFail(_ shouldFail: Bool)
    public func setRefreshShouldFail(_ shouldFail: Bool)
    public func setArtificialDelay(_ delay: Duration)
}

public enum SimulatedPaywallError: Error, Equatable {
    case restoreFailed
    case refreshFailed
}
```

`EntitlementSnapshot` only models `isPro` / `hasPermanentLicense`, so `grantTrial()` yields `isPro == true` and is distinguished from `grantPro()` only in the log line.

### `SwiduxDevPaywallUI`

A separate, opt-in library product (`import SwiduxDevPaywallUI`) providing a bare-bones debug paywall sheet. It mirrors the shape of the vendor paywall UI so the call site is unchanged when a real provider is adopted:

```swift
someView.devPaywall(
    state: store.paywall,
    service: simulatedPaywallService,
    onAction: { store.send(.paywall($0)) }
)
```

The sheet shows the live `PaywallState`, grant buttons, real Restore/Refresh flows, and QA failure/latency toggles. On macOS the sheet uses a 400×600 minimum, matching the vendor paywall UI. Hold a **single** `SimulatedPaywallService` instance and pass it to both `Store.configured()` (as the plugin's `service:`) and `.devPaywall(...)`:

```swift
@State private var paywallService = SimulatedPaywallService()
@State private var store: AppStore

init() {
    let service = SimulatedPaywallService()
    _paywallService = State(initialValue: service)
    _store = State(initialValue: .configured(paywallService: service))
}
```

This is the one place a dev/QA service is intentionally constructed outside `Store.configured()`, because the debug UI must drive the same instance the plugin observes. Swapping to a real provider removes the shared-instance wiring and the `SwiduxDevPaywallUI` import along with the two-line `Store.configured()` change.

## Action semantics

Each case below describes the state mutation the plugin performs and the effect (if any) it returns.

### `request(reason: String)`

Sets `isPresented = true` and stores `requestedReason`. Returns no effect. Dispatch this when a feature needs to gate behind a purchase.

### `dismiss`

Sets `isPresented = false` and clears `requestedReason`. Returns an effect that dispatches `.refreshCustomerInfo` so the entitlement is reconciled after the sheet closes (the user may have purchased while the sheet was up).

### `observeCustomerInfo`

Returns a long-lived effect that consumes `PaywallService.customerInfoStream()` and dispatches `.customerInfoUpdated` for every snapshot. Dispatch once on app launch (typically from a `.task` on the root view). The effect lives for the duration of the stream. Idempotent: `isObservingCustomerInfo` guards against double-subscription, so a re-dispatched `.task` (view identity change, scene reconnect) won't start a duplicate stream.

### `refreshCustomerInfo`

Sets `isLoading = true`. Returns a one-shot effect that calls `PaywallService.customerInfo()` and dispatches `.customerInfoUpdated` on success or `.refreshFailed` on error.

### `customerInfoUpdated(EntitlementSnapshot)`

Sets `isPro` and `hasPermanentLicense` from the snapshot, clears `isLoading`, and clears `error`. Returns no effect. The plugin emits this internally; your code rarely dispatches it directly. Note that the plugin emits this on **every** snapshot (each `customerInfoStream()` value, every `refreshCustomerInfo`/`restorePurchases`), not only on entitlement changes — observe `PaywallState` (or a value derived from it) for transitions rather than mapping this action directly. See <doc:PluginArchitecture#Service-Result-Actions-and-Transition-Observation>.

### `refreshFailed(String)`

Sets `error` to the given message and clears `isLoading`. Returns no effect.

### `restorePurchases`

Sets `isLoading = true`. Returns a one-shot effect that calls `PaywallService.restorePurchases()` and dispatches `.customerInfoUpdated` on success or `.refreshFailed` on error.

### `presentCustomerCenter` / `dismissCustomerCenter`

Toggle `isCustomerCenterPresented`. No effects. Bind these to a separate sheet if your purchase backend exposes a customer-center UI (RevenueCat does).

### `openManageSubscriptions`

Returns an effect that opens `itms-apps://apps.apple.com/account/subscriptions` via the configured `openURL` handler. This deep-links into the Settings → Subscriptions page on iOS and the equivalent on macOS.

## Implementing a `PaywallService`

The plugin is purchase-agnostic. It does not know about products, prices, transactions, or vendor SDKs. Your conformer is responsible for translating whatever a backend reports into an `EntitlementSnapshot`.

The protocol has three methods:

- **`customerInfo() async throws -> EntitlementSnapshot`** — One-shot fetch of the current entitlement. The plugin calls this from `.refreshCustomerInfo`.
- **`customerInfoStream() -> AsyncStream<EntitlementSnapshot>`** — Long-lived stream that yields every time the entitlement changes (purchase completes, subscription expires, family sharing update, etc.). The plugin consumes it from `.observeCustomerInfo`.
- **`restorePurchases() async throws -> EntitlementSnapshot`** — Performs a restore against the user's account and returns the resulting entitlement.

Note what the protocol does **not** require: no product list, no purchase method, no receipt validation. Purchases happen inside whichever paywall UI you present (a RevenueCat paywall view, your own StoreKit-backed sheet, etc.). The plugin only cares about the entitlement that results.

A typical RevenueCat conformer holds a reference to the SDK and bridges its delegate or async APIs into `EntitlementSnapshot` values. A vanilla StoreKit conformer iterates `Transaction.currentEntitlements` and listens to `Transaction.updates`. Either way, the plugin stays the same.

## See Also

- <doc:HowToAddAPaywall>
- <doc:PluginArchitecture>
