# ``Swidux``

Redux-style state management for SwiftUI, with macros for observability and ready-made plugins for persistence, undo, paywalls, version killswitches, and parental gates.

@Metadata {
    @DisplayName("Swidux")
}

## Overview

Swidux is a Redux-style state-management library for SwiftUI. State lives in one observable store, mutations go through reducers, and side effects run as async effects. Macros generate the observability boilerplate. Built-in plugins handle persistence and undo/redo. Three optional plugins ship ready-made paywalls (RevenueCat or StoreKit-shaped), version killswitches, and parental gates.

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

## Topics

### Tutorials

- <doc:BuildingYourFirstApp>

### How-to Guides

- <doc:HowToAddAPaywall>
- <doc:HowToAddAVersionKillswitch>
- <doc:HowToAddAParentalGate>
- <doc:BuildingADomainPlugin>
- <doc:AgentSkill>

### Reference

- <doc:MacrosReference>
- <doc:PluginKillswitchReference>
- <doc:PluginParentalGateReference>
- <doc:PluginPaywallReference>
- <doc:EntityStoreGuide>
- <doc:PersistenceMiddlewareGuide>
- <doc:KeyValueStoreGuide>
- <doc:UndoRedo>
- <doc:GettingStarted>

### Explanation

- <doc:ArchitectureGuide>
- <doc:PluginArchitecture>
- <doc:DesignPrinciples>

### Store

- ``Store``
- ``SwiduxObservable``
- ``SwiduxReducer``
- ``SwiduxDispatcher``
- ``Effect``
- ``Send``

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
