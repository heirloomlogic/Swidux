# Counter — Feature Flags Demo

A self-contained demo of `SwiduxFeatureFlags` for the Counter example app.

The Swift sources here are **not** linked into the Counter Xcode target by default — the
`SwiduxFeatureFlags` product needs to be added to the project first, and these files
need to be added to the target's Compile Sources / Copy Bundle Resources phases.

## Files

- `FeatureFlagsDemo.swift` — `BundledFeatureFlagsService`, typed flag keys, and a SwiftUI
  `FeatureFlagsDemoView` that reads all three flag types.
- `feature-flags.json` — the wire-format config to ship in the app bundle.

## Wiring it in (manual Xcode steps)

1. **Add the package product** to the Counter target: File → Add Packages → select the
   local `Swidux` package and add `SwiduxFeatureFlags` to the Counter target.
2. **Add this folder** to the Counter target so the sources compile and the JSON is copied
   into the bundle: drag `FeatureFlags/` into the Counter group in Xcode, ensure
   "Add to targets: Counter" is checked, and verify `feature-flags.json` appears under
   "Copy Bundle Resources".
3. **Add the slice** to `AppState`:

   ```swift
   import SwiduxFeatureFlags

   @Swidux nonisolated struct AppState: Equatable, Sendable {
       var counters: EntityStore<Counter> = .init()
       @Slice var ui: UIState = .init()
       @Slice var featureFlags: FeatureFlagsState = .init()
   }
   ```

4. **Add the action case** to `AppAction`:

   ```swift
   enum AppAction: Sendable {
       case counter(CounterAction)
       case selectCounter(UUID?)
       case featureFlags(FeatureFlagsAction)
   }
   ```

5. **Route the action** in `AppReducer.reduce(...)`:

   ```swift
   case .featureFlags:
       return nil  // plugin handles it
   ```

6. **Register the plugin** in `Store.configured(...)`:

   ```swift
   let kv = InMemoryKeyValueStore()  // or UserDefaultsKeyValueStore() in real apps
   let flags = FeatureFlagsPlugin<AppState, AppAction>(
       state: \.featureFlags,
       action: AppAction.featureFlags,
       extractAction: { if case .featureFlags(let a) = $0 { return a } else { return nil } },
       service: BundledFeatureFlagsService(),
       refreshPolicy: .manual,
       keyValueStore: kv
   )
   plugins.register(flags)
   ```

7. **Add a navigation entry** in `ContentView` so the demo is reachable, e.g.

   ```swift
   .toolbar {
       NavigationLink("Flags") { FeatureFlagsDemoView() }
   }
   ```

8. Build and run. Tap "Flags", then "Refresh from bundle" — all three flag values will
   render from the JSON shipped in the bundle.
