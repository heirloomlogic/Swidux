# Add a Version Killswitch

Wire a remote-controlled blocker that prevents unsupported app versions from running, with an "Update" path back to the App Store.

## Overview

By the end of this guide your app fetches a JSON config from a URL you control, evaluates it against the running version, and presents a blocking sheet whenever the server marks the build as unsupported. The verdict lives in your `AppState`, so any view can react to it.

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
            plugins: plugins,
            undoPlugin: undoPlugin,
            persistencePlugin: persistencePlugin,
            isUndoable: isUndoable
        )
    }
}
```

The `appVersion` closure runs every time `.fetch` evaluates, so it reflects the build that's actually running. The plugin's default `openURL` argument opens URLs through `UIApplication` or `NSWorkspace`; pass your own closure if you route URLs through a coordinator.

## Step 4: Trigger fetch on launch

Dispatch `.killswitch(.fetch)` from your root view's `.task` so the verdict is available before the user can interact:

```swift
struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ContentView()
            .task { store.send(.killswitch(.fetch)) }
    }
}
```

`.fetch` is cache-aware: if the last fetch is within `cacheLifetime` and a cached config is on disk, the plugin evaluates the cached config and skips the network. That makes a launch fetch cheap to issue on every cold start. For a manual refresh — pull-to-refresh, a "Check for updates" button, or a post-purchase health check — dispatch `.killswitch(.forceFetch)` instead, which bypasses the freshness gate.

If the network call fails and a cached config is available, the plugin dispatches `.verdictReceived(...)` from the cache **and** `.fetchFailed(message)`. Your UI keeps a usable verdict and can still surface the error.

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
| **Cloudflare Worker + Workers KV** *(recommended)* | ✅ `wrangler kv key put` or dashboard | seconds | Flip in seconds, edge-cached, room to add logic (geo/gradual/per-build) later. Runnable example below. |
| Static object (R2 / S3 + CDN) | ✅ re-upload object | seconds (after purge) | Zero code. Must set `Cache-Control` as object metadata; no room to grow. |
| Static site / Pages (git-backed) | ❌ commit + build | ~minutes | The trap: build latency kills the *emergency* use case. |
| GitHub raw / Gist | ✅ edit file | unpredictable | Not a production CDN; you don't control `Cache-Control`, stale exactly when freshness matters. |
| Your own app backend | ✅ | instant | The trap: it's the service most likely down precisely when you need the killswitch. |

**Recommended: Cloudflare Worker + KV.** The config lives in a KV key; the Worker returns it with a short `Cache-Control`. You push an emergency block by writing one KV key — no redeploy. A complete, runnable example is in `Examples/ConfigWorker/` — one Worker, keyed `GET /<appID>/<resource>`, that serves killswitch *and* feature-flag config for every app in a portfolio from a single URL and a single KV namespace (the Cloudflare dashboard becomes the one place you edit a value). The short version: create a KV namespace → seed `…/killswitch` → `wrangler deploy` → point `KillswitchService.live(endpoint:)` at `https://<host>/<appID>/killswitch`. See also `Examples/ConfigWorker/DEPLOY.md` for the multi-app operating convention.

**Minimal alternative: a static object** (Cloudflare R2, S3, any object store fronted by a CDN). Upload `killswitch.json`, set a short `Cache-Control` on the object, re-upload to change it. Zero code; you give up the room to add server-side logic later. Equivalent push-in-seconds latency for this use case.

### Freshness: the backend can't fix client staleness

The plugin caches the fetched config for `cacheLifetime` (**default 3600s**) regardless of how fresh your endpoint is. With the default, a perfectly deployed emergency block still won't reach an already-launched app for up to an hour — and no backend choice changes that. If fast emergency response matters:

- Lower `cacheLifetime` to ~300–900s in `KillswitchService.live(endpoint:fetchTimeout:cacheLifetime:session:)`.
- Dispatch `.killswitch(.forceFetch)` on app-foreground — it bypasses the freshness gate, so a returning user re-checks immediately.

Keep your endpoint's edge `Cache-Control` at or below `cacheLifetime`; caching longer at the edge than the client will re-ask buys nothing.

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
    await effect { dispatched.append($0) }

    if case .killswitch(.verdictReceived(.blocked)) = dispatched.first {
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
