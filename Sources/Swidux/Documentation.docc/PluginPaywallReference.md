# SwiduxPaywall Reference

API reference for the `SwiduxPaywall` library — paywall presentation, entitlement observation, and purchase orchestration.

## Overview

`SwiduxPaywall` is a domain plugin that owns the paywall slice of your app's state and routes paywall actions through the Swidux dispatch cycle. It is provider-agnostic: the plugin knows nothing about RevenueCat, StoreKit, products, prices, or purchase results. You supply a `PaywallService` conformer that talks to whichever purchase backend you use, and the plugin manages presentation state, async progress, and entitlement transitions.

For end-to-end wiring, see <doc:HowToAddAPaywall>. For where this plugin sits in the lifecycle, see <doc:PluginArchitecture>.

## Library target

- Product: `SwiduxPaywall`
- Import: `import SwiduxPaywall`

Add the product to your target dependencies in `Package.swift` alongside `Swidux`.

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

    public init(
        isPro: Bool = false,
        hasPermanentLicense: Bool = false,
        isPresented: Bool = false,
        requestedReason: String? = nil,
        isLoading: Bool = false,
        error: String? = nil,
        isCustomerCenterPresented: Bool = false
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

## Action semantics

Each case below describes the state mutation the plugin performs and the effect (if any) it returns.

### `request(reason: String)`

Sets `isPresented = true` and stores `requestedReason`. Returns no effect. Dispatch this when a feature needs to gate behind a purchase.

### `dismiss`

Sets `isPresented = false` and clears `requestedReason`. Returns an effect that dispatches `.refreshCustomerInfo` so the entitlement is reconciled after the sheet closes (the user may have purchased while the sheet was up).

### `observeCustomerInfo`

Returns a long-lived effect that consumes `PaywallService.customerInfoStream()` and dispatches `.customerInfoUpdated` for every snapshot. Dispatch once on app launch (typically from a `.task` on the root view). The effect lives for the duration of the stream.

### `refreshCustomerInfo`

Sets `isLoading = true`. Returns a one-shot effect that calls `PaywallService.customerInfo()` and dispatches `.customerInfoUpdated` on success or `.refreshFailed` on error.

### `customerInfoUpdated(EntitlementSnapshot)`

Sets `isPro` and `hasPermanentLicense` from the snapshot, clears `isLoading`, and clears `error`. Returns no effect. The plugin emits this internally; your code rarely dispatches it directly.

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
