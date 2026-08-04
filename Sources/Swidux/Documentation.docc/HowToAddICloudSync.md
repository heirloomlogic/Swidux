# Add iCloud Sync

Layer opt-in, cross-device iCloud sync on top of `SwiduxPersistence` with the `SwiduxCloudKitSync` plugin — including a runtime opt-out toggle, launch-time entitlement detection, and the Apple Developer portal configuration.

## Overview

`SwiduxCloudKitSync` adds CloudKit mirroring to the persistence stack from <doc:HowToAddPersistence>. The same generated `@Persisted` models and the same `PersistenceCoordinator` are reused; this works precisely because `@Persisted` generates **CloudKit-safe** models — every non-optional attribute carries a default and every relationship is optional, so the schema validates when SwiftData builds the container with `cloudKitDatabase` set (see <doc:HowToAddPersistence> for the default/optionality rules and their diagnostics). Sync only changes how the `ModelContainer` is built (`cloudKitDatabase` set vs `.none`) and adds three things:

- a **runtime sync toggle** (`SyncCoordinator`) — because SwiftData fixes `cloudKitDatabase` at container creation, toggling rebuilds the container and swaps the active database behind the coordinator's handle, never moving local rows;
- **entitlement & account detection** (`SyncPreflightService` → `SyncStatus`) — degrade to local-only and surface a status rather than crash;
- a **merge-based remote-change observer** that ignores the app's own saves.

**Linking this product is the single signal that an app needs the iCloud / CloudKit / background-remote-notification entitlement family.** A local-only app links only `SwiduxPersistence`.

## Step 1: Configure the App ID, iCloud container, and Push

CloudKit sync requires capabilities on your App ID and a CloudKit container, configured in the Apple Developer portal at <https://developer.apple.com/account/resources/identifiers>.

1. **Open Identifiers** at <https://developer.apple.com/account/resources/identifiers>. Select your app's **App ID** (or create one matching your bundle id, e.g. `com.yourcompany.yourapp`).
2. **Enable iCloud** in the App ID's capability list, and choose **Include CloudKit support**.
3. **Enable Push Notifications** on the same App ID. CloudKit delivers remote-change notifications over APNs, which is what drives `.NSPersistentStoreRemoteChange`.
4. Switch the Identifiers filter to **iCloud Containers** and create a container named `iCloud.<your-bundle-id>` (e.g. `iCloud.com.yourcompany.yourapp`). Back on the App ID, **assign that container** to it.
5. Save. Xcode will regenerate the provisioning profile with these capabilities the next time it signs the app.

The resulting entitlements your built app must carry:

| Entitlement | Value |
|---|---|
| `com.apple.developer.icloud-container-identifiers` | `[iCloud.com.yourcompany.yourapp]` — **non-empty**, matching the id you pass in code |
| `com.apple.developer.icloud-services` | `[CloudKit]` |
| `aps-environment` | `development` in dev builds, `production` in release archives |

> Important: an **empty** `icloud-container-identifiers` array paired with a `CloudKit` services line is misconfiguration, not sync — `SyncPreflightService` will report the app as unavailable. The container id in the portal, the entitlement, and the `cloudKitContainerID` you pass in code must all match.

## Step 2: Add the capabilities in Xcode

In your app target's **Signing & Capabilities** tab:

1. **+ Capability → iCloud.** Check **CloudKit**, then select the `iCloud.<your-bundle-id>` container you created.
2. **+ Capability → Background Modes.** Check **Remote notifications** so the app can receive CloudKit's silent push that fires `.NSPersistentStoreRemoteChange`.
3. **Push Notifications** is added automatically with CloudKit; confirm it's present.

For a SwiftPM-defined app, add the matching keys to your `.entitlements` file and reference it from the target's `CODE_SIGN_ENTITLEMENTS`.

## Step 3: Add the dependency

```swift
.target(
    name: "MyApp",
    dependencies: [
        "Swidux",
        "SwiduxPersistence",
        "SwiduxCloudKitSync",
    ]
)
```

## Step 4: Build a sync-mode container at launch

Read the user's desired mode *before* building the container (the mode determines the `ModelConfiguration`), then build with `CloudContainerFactory`:

```swift
import SwiduxPersistence
import SwiduxCloudKitSync

let containerID = "iCloud.com.yourcompany.yourapp"
let mode = resolveDesiredSyncMode(from: env.keyValue)   // default .iCloud (opt-out)

let container = try CloudContainerFactory.makeContainer(
    models: [CardModel.self],
    mode: mode,
    cloudKitContainerID: containerID
)

let persistence = PersistenceCoordinator<AppState, AppAction>(
    entities: [.entity(\.cards)],
    container: container
)
plugins.register(persistence.corePlugin)
await persistence.hydrate(into: &initial)
```

`resolveDesiredSyncMode(from:)` reads the persisted `KVKey.syncMode`. The default is **sync-on with opt-out** (`.iCloud`) for any app that links this product; pass `default: .localOnly` to make sync strictly opt-in instead.

## Step 5: Wire the sync toggle

`SyncCoordinator` owns the runtime toggle. Give it the persistence coordinator, the model list, the preflight probe, and your `KeyValueStore`:

```swift
let sync = SyncCoordinator<AppState, AppAction>(
    persistence: persistence,
    models: [CardModel.self],
    mode: mode,
    preflight: .live(containerID: containerID),
    keyValue: env.keyValue,
    cloudKitContainerID: containerID
)
```

From a Settings toggle, call `setSyncEnabled(_:into:)` with the **store**, then record the result with a normal dispatch:

```swift
let status = await sync.setSyncEnabled(isOn, into: store)
store.send(.syncSettingsChanged(mode: sync.mode, status: status))
```

`setSyncEnabled` flushes pending writes, resolves availability, rebuilds the container in the *effective* mode (CloudKit only when actually usable, else a local fallback), swaps the active database behind the coordinator's handle, persists the user's choice, and re-hydrates via `merge` (never replace). It returns the resolved `SyncStatus`.

It takes the store rather than `inout State` because all of that is asynchronous. Every one of those `await`s is a window in which the user can keep editing, and a caller holding a state snapshot across them would overwrite whatever landed. Here the flush, preflight, and rebuild all complete first; only then does one suspension-free step pack a fresh snapshot, merge, and unpack. Nothing can interleave between that pack and the follow-up `send` either — the main actor can only be re-entered at a suspension point, and there is none.

## Step 6: Detect availability and degrade gracefully

`SyncPreflightService` probes `FileManager.ubiquityIdentityToken` and `CKContainer.accountStatus`; `SyncStatus.resolve(desired:entitled:account:)` maps the result to a verdict-in-state enum:

| `SyncStatus` | Meaning | Response |
|---|---|---|
| `.localOnlyByChoice` | User opted out | Healthy; running on-device. |
| `.syncing` | Entitled, signed in, active | Healthy. |
| `.unavailableNotSignedIn` | Entitled, no iCloud account | Show a gentle "Sign in to iCloud" banner; never assert. |
| `.unavailableRestricted` | MDM/parental restriction | Inform; run local-only. |
| `.misconfiguredNoEntitlement` | Sync requested but **not entitled** — a build/signing bug | Degrade to local-only; `assertionFailure` in **DEBUG only**, never crash release. |

Run the probe at launch and on `scenePhase → .active`, and disable the Settings toggle when the status isn't actionable by the user:

```swift
let status = await sync.currentStatus()
state.persistence.syncStatus = status
```

The Keychain `−34018` condition (from `KeychainKeyValueStore`, used for analytics device-id) is a separate, always-present capability — it stays detected where it is and is not folded into the sync preflight.

## Step 7: Observe remote changes

Start a `RemoteChangeObserver` while in cloud mode to pull in changes from other devices:

```swift
let observer = RemoteChangeObserver(debounce: .seconds(2)) { [weak store] in
    guard let store else { return }
    await persistence.rehydrate(into: store)   // merge, never replace
}
observer.start()
```

Capture the store **weakly**: the observer usually outlives the view layer, and is typically held by the same object that holds the store.

`.NSPersistentStoreRemoteChange` also fires for the app's *own* local saves. Because re-hydration always **merges preferring in-memory state**, feeding the app its own writes is a no-op — the rule-#8 data-loss trap is neutralized by construction. Call `observer.stop()` before a sync toggle (the coordinator rebuilds the container).

> Warning: Do not hand-roll this by snapshotting state around the `await`:
>
> ```swift
> var snapshot = AppState(observer: store.observer)   // ← packed BEFORE the awaits
> await persistence.rehydrate(into: &snapshot)        // ← the user keeps typing here…
> AppState.apply(snapshot, to: store.observer)        // ← …and those edits are gone
> ```
>
> That loses every write dispatched while the flush and fetches are in flight, and it surfaces as intermittently vanishing keystrokes rather than as an obvious failure. `rehydrate(into:)` takes the store precisely so this shape has no reason to exist; for your own async work, use ``Store/mutate(awaiting:merging:)``.

> Important: The same merge rule makes mid-session sync **additive-only**. Rows created on another device appear live; remote *edits* to entities already in memory and remote *deletions* do **not** surface until the next launch (the in-memory value always wins, and a merge never removes). This is the deliberate trade against clobbering unflushed writes and live UI edits — set expectations accordingly in your UI, and don't chase "stale until relaunch" reports as bugs.

## What the privacy toggle does (and doesn't)

Be accurate about CloudKit semantics in your UI copy:

- Turning sync **off** is reversible and **non-destructive**: it stops further syncing and keeps data on this device. Data already in the user's private CloudKit database stays there until an explicit, confirmed delete — opt-out is *not* deletion.
- Turning sync **on** later merges local and server rows; it never clobbers.

Example UI copy: *"By default your data is stored only on this device. If you turn on iCloud Sync it is stored in your private iCloud account and synced across your devices. Turning it off stops syncing and keeps your data on-device; data already in iCloud remains in your account until you delete it."*

## Testing

The pure parts are unit-testable without entitlements: `SyncStatus.resolve(desired:entitled:account:)` (truth table), `SyncPreflightService.mock(ubiquityToken:account:)`, the `KVKey.syncMode` round-trip, and the opt-out toggle path against an in-memory container. Real two-device CloudKit mirroring requires entitlements and a signed-in device, so cover it with a manual smoke test: two-device sync, opt-out keeps data local, opt-in merges, signed-out iCloud degrades with a banner, and a build missing the entitlement trips the DEBUG assertion.

## See Also

- <doc:HowToAddPersistence>
- <doc:EntityStoreGuide>
- <doc:KeyValueStoreGuide>
