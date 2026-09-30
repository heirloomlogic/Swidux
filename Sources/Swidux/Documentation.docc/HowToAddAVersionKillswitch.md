# Add a Version Killswitch

Wire a remote-controlled blocker that covers the UI of unsupported app versions, with an "Update" path back to the App Store.

## Overview

By the end of this guide your app fetches a JSON config from a URL you control, evaluates it against the running version, and covers the app with a non-dismissible overlay whenever the server marks the build as unsupported. The verdict lives in your `AppState`, so any view can react to it.

## Before you start

This guide assumes you already have a Swidux app wired up: an `AppState`, an `AppAction`, an `AppReducer`, and a `Store.configured()` factory. If not, work through <doc:GettingStarted> first.

## Step 1: Add the dependency

`SwiduxKillswitch` is a separate product in the `Swidux` package. Add it to the target that wires the store:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Swidux", package: "Swidux"),
        .product(name: "SwiduxKillswitch", package: "Swidux"),
    ]
)
```

If you re-export Swidux from `AppState.swift` (recommended), import `SwiduxKillswitch` directly in `AppStore.swift` and `AppState.swift` where the types are referenced.

## Step 2: Add state and actions

Mount a `KillswitchState` slice on your root state and add an action case that wraps `KillswitchAction`:

```swift
// App/AppState.swift
import SwiduxKillswitch

@Swidux
nonisolated struct AppState: Equatable, Sendable {
    @Slice var killswitch: KillswitchState = .init()
    // ... your other slices
}
```

```swift
// App/AppAction.swift
import SwiduxKillswitch

enum AppAction: Sendable {
    case killswitch(KillswitchAction)
    // ... your other cases
}
```

> Tip: `import SwiduxKillswitch` is needed in *every* file that touches `store.killswitch.*` or `KillswitchAction` — including views that read the verdict for display. `@_exported import Swidux` re-exports core Swidux only, not plugin modules. See <doc:PluginArchitecture>.

The plugin's reducer handles `.killswitch` actions itself. Your root reducer should fall through:

```swift
// App/AppReducer.swift
func reduce(
    state: inout AppState,
    action: AppAction,
    environment: AppEnvironment
) -> Effect? {
    switch action {
    case .killswitch:
        return nil
    // ... your other cases
    }
}
```

## Step 3: Wire the plugin

Inside `Store.configured()`, build a `KillswitchPlugin` and register it on the plugin host. Use `KillswitchService.live(endpoint:fetchTimeout:cacheLifetime:session:)` for the production service:

```swift
// App/AppStore.swift
import SwiduxKillswitch

extension Store where State == AppState, Action == AppAction {
    static func configured(environment: AppEnvironment = .live()) -> AppStore {
        // ... existing reducer / undo / persistence setup

        let killswitchPlugin = KillswitchPlugin<AppState, AppAction>(
            state: \.killswitch,
            action: AppAction.killswitch,
            extractAction: {
                if case .killswitch(let a) = $0 { return a }
                return nil
            },
            service: KillswitchService.live(
                endpoint: URL(static: "https://example.com/killswitch.json")
            ),
            appVersion: {
                Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            }
        )

        let plugins = PluginHost<AppState, AppAction>()
        plugins.register(undoPlugin)
        plugins.register(persistencePlugin)
        plugins.register(killswitchPlugin)

        return Store(
            initialState: AppState(),
            reducer: { state, action in
                reducer.reduce(state: &state, action: action, environment: environment)
            },
            plugins: plugins
        )
    }
}
```

The `appVersion` closure runs every time `.fetch` evaluates, so it reflects the build that's actually running. The plugin's default `openURL` argument opens URLs through `UIApplication` or `NSWorkspace`; pass your own closure if you route URLs through a coordinator.

## Step 4: Trigger fetch on launch

Dispatch `.killswitch(.fetch)` from your root view's `.task`, so the verdict is decided as early in the launch as possible:

```swift
struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ContentView()
            .task { store.send(.killswitch(.fetch)) }
    }
}
```

`.fetch` is cache-aware: if a network fetch succeeded within `cacheLifetime` this session and a cached config is on disk, the plugin evaluates the cached config and skips the network. For a manual refresh — pull-to-refresh, a "Check for updates" button, or a post-purchase health check — dispatch `.killswitch(.forceFetch)` instead, which bypasses the freshness gate.

The freshness window is session state, so a cold launch always goes to the network. It doesn't wait on it, though: while the verdict is still `.unknown`, the plugin first evaluates the config cached by a previous launch and dispatches that verdict (`fromNetwork: false`), then asks the network. A build that the device already knows is blocked is blocked as soon as that file is read, not after the request returns. On a first-ever launch there is no cache, so the verdict stays `.unknown` — which renders nothing — until the network answers, for at most `fetchTimeout`.

If the network call fails and a cached config is available, the plugin dispatches `.verdictReceived(...)` from the cache **and** `.fetchFailed(message)`. Your UI keeps a usable verdict and can still surface the error.

Only one network fetch runs at a time. A `.fetch` or `.forceFetch` dispatched while one is in flight (`isFetching`) is dropped, so dispatching both at launch — `.fetch` from `.task` and `.forceFetch` on foreground — costs one request, and a slow response can never land after, and overwrite, a newer one.

## Step 5: Render the verdict

The simplest path is the bundled `killswitchBlocker(verdict:onUpdate:)` view modifier. It overlays a non-dismissible blocker when the verdict is `.blocked` and disables the underlying content while it is:

```swift
struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ContentView()
            .task { store.send(.killswitch(.fetch)) }
            .killswitchBlocker(verdict: store.killswitch.verdict) {
                store.send(.killswitch(.openUpdateURL))
            }
    }
}
```

`.unknown` and `.allowed` render nothing — the blocker only appears once the verdict comes back as `.blocked(...)`. The Update button calls the `onUpdate` closure, which dispatches `.killswitch(.openUpdateURL)`. The plugin checks `canOpenUpdateURL` and opens the URL through `UIApplication` / `NSWorkspace`.

If the default blocker styling doesn't match your design, use the second overload with a custom view builder:

```swift
.killswitchBlocker(verdict: store.killswitch.verdict) { title, message, hasUpdateURL in
    MyBlockerView(
        title: title ?? "Update required",
        message: message,
        showsUpdateButton: hasUpdateURL,
        onUpdate: { store.send(.killswitch(.openUpdateURL)) }
    )
}
```

The closure receives the verdict's `title`, `message`, and a `hasUpdateURL` flag derived from `canOpenUpdateURL`, so your custom view doesn't have to pattern-match the verdict itself.

### What the blocker covers

The modifier is view-local: it disables and overlays the one view you attach it to, and nothing else. The store does not refuse actions while blocked. Anything that reaches the store without going through that view keeps working:

- **Other scenes.** A second `WindowGroup` window, a `Settings` scene, a `MenuBarExtra`. Apply the modifier to the root view of *every* scene.
- **Presentations.** A sheet, popover, or full-screen cover already up when the verdict flips is drawn above the overlay. Dismiss them when `store.killswitch.isBlocked` becomes true — drive each presentation's binding off state and clear it on the transition, or gate the `isPresented` getter on `!store.killswitch.isBlocked`.
- **Commands and system entry points.** macOS menu commands (including Edit > Undo), keyboard shortcuts, App Intents, `onOpenURL`, and notification actions dispatch without touching the view tree. Disable your `Commands` with `.disabled(store.killswitch.isBlocked)`, and have intent and URL handlers check `isBlocked` before dispatching.

```swift
@main
struct MyApp: App {
    @State private var store = AppStore.configured()

    var body: some Scene {
        WindowGroup {
            RootView()
                .killswitchBlocker(verdict: store.killswitch.verdict) {
                    store.send(.killswitch(.openUpdateURL))
                }
                .environment(store)
        }
        .commands {
            CommandMenu("Items") {
                Button("New Item") { store.send(.items(.add)) }
                    .keyboardShortcut("n")
                    .disabled(store.killswitch.isBlocked)
            }
        }

        Settings {
            SettingsView()
                .killswitchBlocker(verdict: store.killswitch.verdict)
                .environment(store)
        }
    }
}
```

The blocker is a courtesy for a cooperative user, not enforcement — see <doc:SecurityPosture>. What it should not be is leaky by omission.

## Hosting the JSON config

The endpoint you pass to `KillswitchService.live(endpoint:fetchTimeout:cacheLifetime:session:)` serves a JSON document matching `KillswitchConfig`. Every field is optional. The four operational shapes you'll actually use:

**1. Soft minimum version (most common).** Force everyone below the floor to update; let everyone else through.

```json
{
    "minimumSupportedVersion": "1.2.0",
    "blockedTitle": "Update required",
    "blockedMessage": "Please update Counter to keep using it.",
    "updateURL": "https://apps.apple.com/app/id000000000"
}
```

**2. Emergency block of a specific bad build.** A point release shipped with a corruption bug; block exactly those builds and let everyone else continue.

```json
{
    "blockedVersions": ["1.4.2", "1.4.3"],
    "blockedTitle": "Critical update available",
    "blockedMessage": "This build has a known data-loss issue. Please update.",
    "updateURL": "https://apps.apple.com/app/id000000000"
}
```

**3. Range block.** A whole range of builds is unsupported (e.g., everything between two breaking server changes).

```json
{
    "blockedRanges": ["1.4.0..<1.4.5"],
    "blockedTitle": "Update required",
    "blockedMessage": "Builds 1.4.0 through 1.4.4 are no longer supported.",
    "updateURL": "https://apps.apple.com/app/id000000000"
}
```

Range entries use the literal string `"a.b.c..<x.y.z"` — half-open, lower bound inclusive, upper bound exclusive.

Every version in the config must be full `major.minor.patch` with no prefix or surrounding whitespace, even though the app's own marketing version may be `"2.0"`. A rule that doesn't parse is ignored — the app is *not* blocked — and logged at error level (`swidux` / `killswitch` in Console). Test an incident config against a device before you rely on it.

**4. Allow everyone.** Sometimes you just want the killswitch live but quiet.

```json
{}
```

Rules combine. Adding all of them in one document lets you lift the floor *and* knock out a specific bad build *and* gate a known-broken range — checks run minimum-version → blocked-versions → blocked-ranges, returning the first match:

```json
{
    "minimumSupportedVersion": "1.2.0",
    "blockedVersions": ["1.4.2"],
    "blockedRanges": ["1.5.0..<1.5.3"],
    "blockedTitle": "Update required",
    "blockedMessage": "Please update Counter to keep using it.",
    "updateURL": "https://apps.apple.com/app/id000000000"
}
```

### Where to host it

The contract is small: a public `GET` that returns `KillswitchConfig`-shaped JSON. It's read on every cold launch, the plugin is fail-open, and it caches the result client-side — so the backend can be trivial. The one requirement that actually shapes the choice: **a killswitch's value is how fast you can push an emergency block.** Anything that needs a redeploy or a git build to change the config defeats the purpose.

| Option | Change config without redeploy? | Propagation | Notes |
|---|---|---|---|
| **Cloudflare Worker + Workers KV** *(recommended)* | ✅ `wrangler kv key put` or dashboard | about 60 s | A KV write can take 60 seconds or more to reach every Cloudflare location. Room to add logic (geo/gradual/per-build) later. Runnable example below. |
| Static object (R2 / S3 + CDN) | ✅ re-upload object | seconds (after purge) | Zero code. Must set `Cache-Control` as object metadata; no room to grow. |
| Static site / Pages (git-backed) | ❌ commit + build | ~minutes | The trap: build latency kills the *emergency* use case. |
| GitHub raw / Gist | ✅ edit file | unpredictable | Not a production CDN; you don't control `Cache-Control`, stale exactly when freshness matters. |
| Your own app backend | ✅ | instant | The trap: it's the service most likely down precisely when you need the killswitch. |

**Recommended: Cloudflare Worker + KV.** The config lives in a KV key, and the Worker reads it on every request. You push an emergency block by writing one KV key — no redeploy. A complete, runnable example is in `Examples/ConfigWorker/` — one Worker, keyed `GET /<appID>/<resource>`, that serves killswitch *and* feature-flag config for every app in a portfolio from a single URL and a single KV namespace (the Cloudflare dashboard becomes the one place you edit a value). The short version: create a KV namespace → seed `…/killswitch` → `wrangler deploy` → point `KillswitchService.live(endpoint:)` at `https://<host>/<appID>/killswitch`. The example accepts an app ID only if it matches `[a-z0-9][a-z0-9-]{0,63}`: lowercase letters, digits, and hyphens, starting with a letter or digit, 64 characters at most. Any other app ID, a bundle ID such as `com.example.Counter` included, gets a 404, which the plugin treats as a failed fetch. See also `Examples/ConfigWorker/DEPLOY.md` for the multi-app operating convention.

**Minimal alternative: a static object** (Cloudflare R2, S3, any object store fronted by a CDN). Upload `killswitch.json`, set a short `Cache-Control` on the object, re-upload to change it. Zero code; you give up the room to add server-side logic later. Equivalent push-in-seconds latency for this use case.

### Freshness: the backend can't fix client staleness

However fast your endpoint changes, an app sees the new config only when it asks for it:

- A cold launch always goes to the network, because the freshness window is session state (see Step 4).
- A running app goes back to the network only when something dispatches `.forceFetch`, or `.fetch` once `cacheLifetime` has passed. Wired as in Step 4, with one `.fetch` in the root view's `.task`, nothing dispatches either while that view stays on screen, so a running app doesn't re-check however long it runs.
- Dispatch `.killswitch(.forceFetch)` when the app returns to the foreground. That is what gets an emergency block to apps that are already running.
- `cacheLifetime` (**default 3600s**) only decides whether a repeated `.fetch` goes to the network or reuses the cached config. Lower it (300–900s, say) in `KillswitchService.live(endpoint:fetchTimeout:cacheLifetime:session:)` if you re-dispatch `.fetch` on a timer or on foreground instead of `.forceFetch`.

Your endpoint's `Cache-Control` header doesn't affect Swidux clients: `KillswitchService.live` requests with `reloadIgnoringLocalCacheData`, so the local URL cache is never consulted. The header does control any cache between the app and your origin, such as the CDN in front of a static object, and those caches can hold an old config for up to its `max-age`.

## Testing

Use `KillswitchService.mock(result:cached:cacheLifetime:)` to drive the plugin from a test without hitting the network:

```swift
@MainActor
@Test func blockedVersion_yieldsBlockedVerdict() async throws {
    var state = AppState()
    let plugin = KillswitchPlugin<AppState, AppAction>(
        state: \.killswitch,
        action: AppAction.killswitch,
        extractAction: { if case .killswitch(let a) = $0 { return a }; return nil },
        service: .mock(result: {
            KillswitchConfig(minimumSupportedVersion: "2.0.0")
        }),
        appVersion: { "1.0.0" },
        openURL: { _ in }
    )

    let effect = try #require(
        plugin.reduce(state: &state, action: .killswitch(.fetch))
    )

    var dispatched: [AppAction] = []
    try await effect { dispatched.append($0) }

    if case .killswitch(.verdictReceived(.blocked, fromNetwork: true)) = dispatched.first {
        // pass
    } else {
        Issue.record("expected blocked verdict, got \(dispatched)")
    }
}
```

The mock factory's `result` closure can also throw. With no cached config, the plugin dispatches only `.fetchFailed`. With a cached config, it dispatches `.verdictReceived(...)` from cache **and** `.fetchFailed`, so test the fallback path with both `result:` and `cached:` set:

```swift
service: .mock(
    result: { throw URLError(.notConnectedToInternet) },
    cached: KillswitchConfig(minimumSupportedVersion: "1.0.0")
)
```

## See Also

- <doc:PluginKillswitchReference>
- <doc:PluginArchitecture>
