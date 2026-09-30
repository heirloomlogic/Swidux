# SwiduxKillswitch Reference

Public API surface for the `SwiduxKillswitch` library — the plugin, its state and actions, the service abstraction, and the version-comparison primitives.

## Library target

`SwiduxKillswitch` ships as its own product in the `Swidux` package. Add it to a target's dependencies in `Package.swift` and import it where you wire the plugin:

```swift
import SwiduxKillswitch
```

The target depends on `Swidux` and links against `UIKit` on iOS / `AppKit` on macOS for the default URL-opening behavior.

## Types

### KillswitchPlugin

The domain plugin. Conforms to `SwiduxPlugin` and is generic over the host app's root state and action types.

```swift
@MainActor
public struct KillswitchPlugin<RootState, RootAction>: SwiduxPlugin {
    public typealias State = RootState
    public typealias Action = RootAction

    public init(
        state: WritableKeyPath<RootState, KillswitchState>,
        action toRootAction: @escaping @Sendable (KillswitchAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> KillswitchAction?,
        service: KillswitchService,
        appVersion: @escaping @Sendable () -> String,
        openURL: @escaping @Sendable (URL) async -> Void = { /* UIApplication / NSWorkspace */ }
    )
}
```

The default `openURL` calls `UIApplication.shared.open(_:)` on iOS and `NSWorkspace.shared.open(_:)` on macOS, both hopped to `MainActor`.

### KillswitchState

The state slice the plugin owns. Default-constructed values match a fresh, never-fetched session.

```swift
public struct KillswitchState: Sendable, Equatable {
    public var verdict: KillswitchVerdict   // defaults to .unknown
    public var lastFetch: Date?             // nil until first successful fetch
    public var fetchError: String?          // localized description of last failure
    public var isFetching: Bool             // true while a network fetch is in flight

    public var isBlocked: Bool              // delegates to verdict.isBlocked
    public var canOpenUpdateURL: Bool       // .blocked AND updateURL is https, itms-apps, or macappstore

    public init(
        verdict: KillswitchVerdict = .unknown,
        lastFetch: Date? = nil,
        fetchError: String? = nil,
        isFetching: Bool = false
    )
}
```

`isBlocked` and `canOpenUpdateURL` are convenience computed properties. Bind UI off them rather than pattern-matching `verdict` everywhere. `canOpenUpdateURL` is `verdict.openableUpdateURL != nil`, so a blocked verdict whose `updateURL` uses any other scheme (`http`, say) shows the default blocker without an Update button.

### KillswitchAction

The plugin's local action enum. Wrap these in your root action through the case you provide at registration.

```swift
public enum KillswitchAction: Sendable {
    case fetch
    case forceFetch
    case verdictReceived(KillswitchVerdict, fromNetwork: Bool)
    case fetchFailed(String)
    case openUpdateURL
}
```

`.fetch` is the launch-time entry point — it consults the cache and skips the network when the cached config is fresh. `.forceFetch` always hits the network, suitable for pull-to-refresh or post-update health checks. Neither starts a second request while one is in flight.

### KillswitchService

A closure-based service that fetches and caches the remote config. Substitute the live factory in production and the mock factory in tests.

```swift
public struct KillswitchService: Sendable {
    public var fetch: @Sendable () async throws -> KillswitchConfig
    public var loadCached: @Sendable () -> KillswitchConfig?
    public var saveCached: @Sendable (KillswitchConfig) -> Void
    public let cacheLifetime: TimeInterval
    public let fetchTimeout: TimeInterval

    public init(
        fetch: @escaping @Sendable () async throws -> KillswitchConfig,
        loadCached: @escaping @Sendable () -> KillswitchConfig?,
        saveCached: @escaping @Sendable (KillswitchConfig) -> Void,
        cacheLifetime: TimeInterval,
        fetchTimeout: TimeInterval = 30
    )

    public static func live(
        endpoint: URL,
        fetchTimeout: TimeInterval = 10,
        cacheLifetime: TimeInterval = 3600,
        session: URLSession = .shared
    ) -> KillswitchService

    public static func mock(
        result: @escaping @Sendable () async throws -> KillswitchConfig = { KillswitchConfig() },
        cached: KillswitchConfig? = nil,
        cacheLifetime: TimeInterval = 3600
    ) -> KillswitchService
}
```

`live(endpoint:)` decodes JSON from `endpoint` with a `reloadIgnoringLocalCacheData` policy and persists the result to `swidux-killswitch.json` in a **bundle-scoped subdirectory** of the user's caches directory. The stored payload records the endpoint it came from, and a cache written for a different endpoint reads as absent — the cached config produces a verdict with the same authority a fetched one does, so it is scoped and checked rather than trusted. See <doc:SecurityPosture> §6a. `mock(result:cached:)` keeps an in-memory cache and lets a test inject a closure that returns or throws.

`fetchTimeout` is the plugin's own bound on `fetch`, whatever the service does inside it. Only one network fetch runs at a time, so a custom `fetch` that never returned would otherwise hold `isFetching`, and every later `.fetch` and `.forceFetch`, for the session. Past the bound the plugin abandons the call, even one that ignores cancellation, and handles it as a failure (`URLError.timedOut`): cache fallback plus `.fetchFailed`. It defaults to 30 seconds for a custom service; `live` uses its own `fetchTimeout`. A value that isn't finite and positive means no bound.

The endpoint must be **HTTPS** (`http` is allowed only for `localhost` development servers; anything else is a precondition failure) — the killswitch is a remote control channel and must not be tamperable in transit. Non-2xx responses, payloads over 1 MB, and fetches that run past `fetchTimeout` are treated as fetch failures, which fall back to the cache (and ultimately fail open). `fetchTimeout` bounds the whole fetch, headers and body together; it is not just an idle timeout, so a response trickled in a byte at a time still fails on schedule.

### KillswitchConfig

The decoded shape of the remote JSON. All fields are optional — a config with every field `nil` evaluates to `.allowed`.

```swift
public struct KillswitchConfig: Codable, Sendable, Equatable {
    public var minimumSupportedVersion: String?
    public var blockedVersions: [String]?
    public var blockedRanges: [String]?
    public var blockedTitle: String?
    public var blockedMessage: String?
    public var updateURL: String?

    public init(
        minimumSupportedVersion: String? = nil,
        blockedVersions: [String]? = nil,
        blockedRanges: [String]? = nil,
        blockedTitle: String? = nil,
        blockedMessage: String? = nil,
        updateURL: String? = nil
    )
}
```

### KillswitchVerdict

The result of evaluating a config against the running version.

```swift
public enum KillswitchVerdict: Sendable, Equatable {
    case unknown
    case allowed
    case blocked(title: String?, message: String?, updateURL: URL?)

    public var isBlocked: Bool

    public static func evaluate(
        _ config: KillswitchConfig,
        against currentVersionString: String
    ) -> KillswitchVerdict
}
```

`.unknown` is the initial state before any fetch has been attempted. `evaluate(_:against:)` always returns `.allowed` or `.blocked(...)` — never `.unknown`. `isBlocked` is `true` only for the `.blocked` case.

### SemanticVersion

A SemVer 2.0.0 parser used internally to compare versions. Public so you can construct or compare versions directly in tests.

```swift
public struct SemanticVersion: Sendable, Hashable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [PrereleaseIdentifier]

    public init(
        major: Int,
        minor: Int,
        patch: Int,
        prerelease: [PrereleaseIdentifier] = []
    )

    public init?(_ string: String)

    public enum PrereleaseIdentifier: Sendable, Hashable, Comparable {
        case numeric(Int)
        case alphanumeric(String)
    }
}
```

The string initializer accepts `"1.2.3"`, `"1.2.3-beta.1"`, and `"1.2.3-beta.1+build42"`. Build metadata after `+` is parsed and discarded. Malformed input returns `nil`.

Comparison follows the SemVer 2.0.0 precedence rules: numeric major/minor/patch first, then prerelease (a version with a prerelease tag has lower precedence than the same version without), then prerelease identifiers compared left-to-right with numeric identifiers ordering before alphanumeric.

### VersionRange

A half-open range `[lowerBound, upperBound)` of semantic versions, used to express `blockedRanges` entries.

```swift
public struct VersionRange: Sendable, Hashable {
    public let lowerBound: SemanticVersion
    public let upperBound: SemanticVersion

    public init?(lowerBound: SemanticVersion, upperBound: SemanticVersion)
    public init?(_ string: String)   // parses "a.b.c..<x.y.z"

    public func contains(_ version: SemanticVersion) -> Bool
}
```

Both initializers fail and return `nil` if the lower bound is not strictly less than the upper bound, or if either side cannot be parsed.

## Action semantics

| Action | Effect on state | Returned effect |
|---|---|---|
| `.fetch` | ignored while `isFetching`. If the window is fresh (`0 <= Date() - lastFetch < cacheLifetime`) and `loadCached()` returns a config, sets `verdict` from it and clears `fetchError` right there in the reducer, leaving `lastFetch` alone; otherwise sets `isFetching` | none for a fresh-window cache hit — the verdict is already applied, so no later action can land after, and overwrite, a newer network verdict. Otherwise behaves like `.forceFetch`. `lastFetch` is session state, so every cold launch goes to the network |
| `.forceFetch` | ignored while `isFetching`; otherwise sets `isFetching` | if `verdict` is still `.unknown` (a cold launch) and a cached config exists, first dispatches its verdict with `fromNetwork: false`, so a build the device already knows is blocked is blocked before the network answers. Then calls `service.fetch()`, persists the result via `service.saveCached(_:)`, and dispatches `.verdictReceived(..., fromNetwork: true)`. On thrown error, falls back to `service.loadCached()` if it wasn't already shown — dispatching `.verdictReceived(...)` from the cache **and** `.fetchFailed(message)` so the UI can surface the error while keeping a usable verdict |
| `.verdictReceived(verdict, fromNetwork:)` | sets `verdict`, clears `fetchError`; sets `lastFetch = Date()` and clears `isFetching` **only when `fromNetwork` is true** — a cache-served verdict must not slide the freshness window, or a session polling `.fetch` inside `cacheLifetime` would never consult the network again, and the cold-launch preview arrives while the request is still in flight | none |
| `.fetchFailed(message)` | sets `fetchError = message`, clears `isFetching` (does not clear `verdict` or `lastFetch`) | none |
| `.openUpdateURL` | none | if `verdict` is `.blocked` with a non-nil `updateURL` whose scheme is `https`, `itms-apps`, or `macappstore`, calls the plugin's `openURL` closure; otherwise no effect (the URL comes from remote config, so arbitrary schemes are never opened) |

The plugin only handles its own actions. Any action that `extractAction` returns `nil` for is ignored — the plugin's `reduce(...)` returns `nil` immediately.

The combination of `.forceFetch`'s cached-fallback behavior and `.fetch`'s cache-freshness gate is the basis for the plugin's offline tolerance: a launch on a flaky network still yields a verdict (cached) and an error indicator (`fetchError`), without leaving the UI stuck on `.unknown`.

> Note: `.verdictReceived` is dispatched on every network fetch (and its cold-launch preview or cache fallback), usually with an unchanged verdict; a fresh-window `.fetch` applies its cached verdict without one. Consume verdict transitions by observing `KillswitchState` or a value derived from it — not by mapping this action. See <doc:PluginArchitecture#Service-Result-Actions-and-Transition-Observation>.

## Verdict evaluation rules

`KillswitchVerdict.evaluate(_:against:)` is fail-open: any unparseable input yields `.allowed`. Checks run in this fixed order, returning `.blocked(...)` on the first match:

1. **Current version parse.** If `currentVersionString` cannot be parsed as a `SemanticVersion`, return `.allowed` immediately.
2. **Minimum supported version.** If `config.minimumSupportedVersion` parses and `currentVersion < minVersion`, return `.blocked(...)`.
3. **Explicit blocked versions.** Iterate `config.blockedVersions`. If any entry parses and equals `currentVersion`, return `.blocked(...)`.
4. **Blocked ranges.** Iterate `config.blockedRanges`. If any entry parses as a `VersionRange` and contains `currentVersion`, return `.blocked(...)`.
5. **Otherwise** return `.allowed`.

A blocked verdict carries the config's `blockedTitle`, `blockedMessage`, and `updateURL` (parsed via `URL(string:)`) regardless of which check matched.

Config-side versions parse strictly: `"2.0"`, `"v2.0.0"`, and `" 2.0.0"` (stray whitespace from a dashboard paste) are all rejected, as are ranges with spaces around `..<` or a lower bound that isn't below the upper. A rejected rule never matches, so it fails open. Every evaluation logs each rejected rule at error level to the `swidux` subsystem, `killswitch` category, with the offending string public — check Console after publishing an incident config, because the endpoint will happily serve a rule no client can apply.

## Diagnostics

The killswitch fails open, so a broken config channel leaves the app usable and shows nothing on screen. These log lines, all under the `swidux` subsystem, are where it shows up instead. None of them changes the verdict.

- **A failed network fetch** logs at error level, `killswitch` category, with a summary of the error. With `KillswitchService.live` the line also names the endpoint, without its query, fragment, or credentials. A non-2xx response names its status, so a wrong URL reads as `HTTP 404`. A failure identical to the last one logged is skipped until a fetch succeeds, so a device that stays offline logs the outage once. A cancelled fetch isn't logged. `fetchError` records every failure either way.
- **A version rule that fails strict parsing** logs at error level on every evaluation. See <doc:PluginKillswitchReference#Verdict-evaluation-rules>.
- **In debug builds, a top-level key `KillswitchConfig` doesn't declare** logs at warning level, `killswitch` category, on each fetch through `live`. A misspelled `minimumSupportedVerison` decodes as a config with no minimum, and this line is how you find it. Release builds don't log it, because a field added for newer builds is unknown to older ones by design.
- **In debug builds, a 2xx response carrying `X-Config-Source: default`** logs at warning level, `remoteconfig` category. A config worker can send that header when nothing is stored under the requested key and it serves its fallback instead, which usually means the app ID in the URL is wrong. `Examples/ConfigWorker` doesn't send this header.

## Remote config JSON shape

The JSON keys are `KillswitchConfig`'s property names. A representative file:

```json
{
    "minimumSupportedVersion": "1.2.0",
    "blockedVersions": ["1.3.0", "1.3.1"],
    "blockedRanges": ["1.4.0..<1.4.5"],
    "blockedTitle": "Update Required",
    "blockedMessage": "Please update to continue using the app.",
    "updateURL": "https://apps.apple.com/app/id000000000"
}
```

Every field is optional. An empty object `{}` is valid and evaluates to `.allowed` for any version.

### Schema evolution

`KillswitchConfig` has no `version` field and no `type` discriminator, and its decoding ignores keys it doesn't declare. Debug builds log them on a fetch through `live` (see <doc:PluginKillswitchReference#Diagnostics>); release builds don't. A field added for newer builds therefore never makes an older build reject the document, so feature flags' unknown-type problem (see <doc:PluginFeatureFlagsReference#Schema-evolution>) has no killswitch counterpart.

The risk runs the other way: an older build ignores a field it predates without any error, and older builds are usually the ones an incident needs to block. **Never express a block for old builds with a field those builds don't decode.** Use `minimumSupportedVersion`, `blockedVersions`, or `blockedRanges`, which every release of `SwiduxKillswitch` has decoded.

## View modifier: `killswitchBlocker`

`SwiduxKillswitch` ships a SwiftUI view modifier that overlays a non-dismissible blocker whenever the verdict is `.blocked` and disables the underlying content while it is. Two overloads:

```swift
extension View {
    /// Default blocker — full-screen ultraThinMaterial with title, message,
    /// and an optional Update button.
    public func killswitchBlocker(
        verdict: KillswitchVerdict,
        onUpdate: (() -> Void)? = nil
    ) -> some View

    /// Custom blocker — receives the title, message, and `hasUpdateURL`
    /// flag and renders whatever you return.
    public func killswitchBlocker<Blocker: View>(
        verdict: KillswitchVerdict,
        @ViewBuilder blocker: @escaping (
            _ title: String?,
            _ message: String?,
            _ hasUpdateURL: Bool
        ) -> Blocker
    ) -> some View
}
```

Both overloads apply `.disabled(verdict.isBlocked)` to the modified content, so the underlying view tree stops responding to touches while blocked. The blocker layer is rendered as an overlay; supply your own to match the host app's design system.

The modifier is view-local. It covers only the view it is applied to, and the plugin does not gate dispatch while blocked: other scenes, presentations already on screen (drawn above the overlay), menu commands, keyboard shortcuts, App Intents, and URL handlers all keep working unless you gate them. Apply the modifier to every scene's root, dismiss presentations when `isBlocked` becomes true, and disable commands on `isBlocked`. See <doc:HowToAddAVersionKillswitch#What-the-blocker-covers>.

## See Also

- <doc:HowToAddAVersionKillswitch>
- <doc:PluginArchitecture>
