# ``Swidux``

Redux-style state management for SwiftUI, with macros for observability and ready-made plugins for persistence, undo, paywalls, version killswitches, and parental gates.

@Metadata {
    @DisplayName("Swidux")
}

## Overview

![Swidux logo](Swidux-logo)

Swidux is a Redux-style state-management library for SwiftUI. State lives in one observable store, mutations go through reducers, and side effects run as async effects. Macros generate the observability boilerplate. Built-in plugins handle persistence and undo/redo. Optional plugins ship ready-made paywalls (RevenueCat or StoreKit-shaped), version killswitches, parental gates, analytics (Mixpanel or any backend), feature flags, and SwiftData/iCloud persistence.

The dispatch cycle:

```
View → store.send(.action)
  → willReduce hooks (UndoPlugin snapshots here)
  → reducer mutates state in place, optionally returns Effect
  → plugin reducers handle their own actions
  → afterReduce hooks (PersistencePlugin drains EntityStore changelogs here)
  → observer tree updates only changed properties (per-property observation)
  → effects run on a background actor; results dispatch back via @MainActor send
```

Your domain types and database stay in your app. Swidux provides the contracts, observability, and dispatch loop.

## Companion Packages

Vendor-specific adapters live in their own repositories so a third-party SDK never enters the core dependency graph. Each ships a drop-in service conformer plus a preview mock, and publishes its own DocC reference:

- [SwiduxRevenueCatPaywall](https://heirloomlogic.github.io/SwiduxRevenueCatPaywall/documentation/swiduxrevenuecatpaywall/) — RevenueCat adapter for the paywall plugin (`RevenueCatPaywallService`, `MockRevenueCatPaywallService`, and the `SwiduxRevenueCatPaywallUI` sheet). See <doc:HowToAddAPaywall> and <doc:PluginPaywallReference>.
- [SwiduxMixpanelAnalytics](https://heirloomlogic.github.io/SwiduxMixpanelAnalytics/documentation/swiduxmixpanelanalytics/) — Mixpanel adapter for the analytics plugin (`MixpanelAnalyticsService`, `MockMixpanelAnalyticsService`). See <doc:HowToAddAnalytics> and <doc:PluginAnalyticsReference>.

## Topics

### Tutorials

- <doc:BuildingYourFirstApp>

### How-to Guides

- <doc:HowToAddAPaywall>
- <doc:HowToAddAVersionKillswitch>
- <doc:HowToAddAParentalGate>
- <doc:HowToAddAnalytics>
- <doc:HowToAddFeatureFlags>
- <doc:HowToCancelEffects>
- <doc:HowToAddPersistence>
- <doc:HowToAddICloudSync>
- <doc:BuildingADomainPlugin>
- <doc:AgentSkill>

### Reference

- <doc:MacrosReference>
- <doc:PluginKillswitchReference>
- <doc:PluginParentalGateReference>
- <doc:PluginPaywallReference>
- <doc:PluginAnalyticsReference>
- <doc:PluginFeatureFlagsReference>
- <doc:EntityStoreGuide>
- <doc:PersistenceMiddlewareGuide>
- <doc:KeyValueStoreGuide>
- <doc:UndoRedo>
- <doc:GettingStarted>
- <doc:Troubleshooting>

### Explanation

- <doc:ArchitectureGuide>
- <doc:PluginArchitecture>
- <doc:DesignPrinciples>
- <doc:SecurityPosture>

### Store

- ``Store``
- ``Store/mutate(awaiting:merging:)``
- ``SwiduxObservable``
- ``SwiduxReducer``
- ``SwiduxDispatcher``
- ``Effect``
- ``Send``
- ``cancellable(id:cancelInFlight:_:)``
- ``cancel(id:)``

### Data

- ``EntityStore``
- ``ChangeSet``

### Persistence & Undo

- ``PersistencePlugin``
- ``StateWriter``
- ``UndoPlugin``

### Preferences

- ``KeyValueStore``
- ``KVKey``
- ``UserDefaultsKeyValueStore``
- ``InMemoryKeyValueStore``

### Plugin Protocol

- ``SwiduxPlugin``
- ``PluginHost``
