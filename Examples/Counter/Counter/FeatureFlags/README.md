# Counter — Feature Flags Demo

`SwiduxFeatureFlags` demo wired into the Counter example app.

## What's here

- `FeatureFlagsDemo.swift` — `BundledFeatureFlagsService`, typed flag keys, the `FlagManifest` governance list, and a `FeatureFlagsDemoView` that reads all three flag types.
- `feature-flags.json` — the wire-format config shipped in the app bundle.

The Counter Xcode project's "Counter" target already links the `SwiduxFeatureFlags`
package product and uses a synchronized folder group, so this folder is picked up
automatically.

## How it's wired

- `AppState` has `@Slice var featureFlags: FeatureFlagsState`.
- `AppAction` has `case featureFlags(FeatureFlagsAction)`.
- `AppReducer` routes the case (the plugin owns all state mutation).
- `AppStore.configured(...)` registers a `FeatureFlagsPlugin` backed by `BundledFeatureFlagsService`, and mints a `deviceID` (via `KeyValueStore.deviceIdentity()`) as the stable bucketing identity passed through `deviceIDKeyPath: \.deviceID`. This demo persists it to UserDefaults so it runs in any build; a shipping app uses `KeychainKeyValueStore` so the identity survives reinstall.
- `ContentView`'s toolbar has a "Flags" `NavigationLink` to `FeatureFlagsDemoView`.

## No forever flags

`FlagManifest.all` carries each flag's required owner + expiry, and `FeatureFlagGovernanceTests.noForeverFlags` (in `CounterTests`) fails — naming the flag and owner — when any flag outlives its expiry. Owner/expiry are enforced because the `FlagDescriptor` factories require them.

Build the Counter scheme and tap the flag icon in the toolbar. Use "Refresh from bundle"
to fetch the local JSON; the three sections render the boolean, variant, and value flags.

## Customizing

Edit `feature-flags.json` to change rollout percentages, variant weights, or value
defaults — the demo re-reads on every `.refresh` dispatch. Typed key declarations
live at the bottom of `FeatureFlagsDemo.swift` for easy extension.
