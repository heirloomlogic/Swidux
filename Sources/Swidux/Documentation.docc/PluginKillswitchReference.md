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

    public var isBlocked: Bool              // delegates to verdict.isBlocked
    public var canOpenUpdateURL: Bool       // .blocked AND updateURL is non-nil

    public init(
        verdict: KillswitchVerdict = .unknown,
        lastFetch: Date? = nil,
        fetchError: String? = nil
    )
}
```

`isBlocked` and `canOpenUpdateURL` are convenience computed properties. Bind UI off them rather than pattern-matching `verdict` everywhere.

### KillswitchAction

The plugin's local action enum. Wrap these in your root action through the case you provide at registration.

```swift
public enum KillswitchAction: Sendable {
    case fetch
    case forceFetch
    case verdictReceived(KillswitchVerdict)
    case fetchFailed(String)
    case openUpdateURL
}
```

`.fetch` is the launch-time entry point — it consults the cache and skips the network when the cached config is fresh. `.forceFetch` always hits the network, suitable for pull-to-refresh or post-update health checks.

### KillswitchService

A closure-based service that fetches and caches the remote config. Substitute the live factory in production and the mock factory in tests.

```swift
public struct KillswitchService: Sendable {
    public var fetch: @Sendable () async throws -> KillswitchConfig
    public var loadCached: @Sendable () -> KillswitchConfig?
    public var saveCached: @Sendable (KillswitchConfig) -> Void
    public let cacheLifetime: TimeInterval

    public init(
        fetch: @escaping @Sendable () async throws -> KillswitchConfig,
        loadCached: @escaping @Sendable () -> KillswitchConfig?,
        saveCached: @escaping @Sendable (KillswitchConfig) -> Void,
        cacheLifetime: TimeInterval
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

`live(endpoint:)` decodes JSON from `endpoint` with a `reloadIgnoringLocalCacheData` policy and persists the result to a `swidux-killswitch.json` file in the user's caches directory. `mock(result:cached:)` keeps an in-memory cache and lets a test inject a closure that returns or throws.

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
| `.fetch` | none | if the cache is fresh (`Date() - lastFetch < cacheLifetime` AND `loadCached()` is non-nil), evaluates the cached config and dispatches `.verdictReceived(...)` without hitting the network; otherwise behaves like `.forceFetch` |
| `.forceFetch` | none | calls `service.fetch()`, persists the result via `service.saveCached(_:)`, dispatches `.verdictReceived(...)`. On thrown error, falls back to `service.loadCached()` if available — dispatching `.verdictReceived(...)` from the cache **and** `.fetchFailed(message)` so the UI can surface the error while keeping a usable verdict |
| `.verdictReceived(verdict)` | sets `verdict`, sets `lastFetch = Date()`, clears `fetchError` | none |
| `.fetchFailed(message)` | sets `fetchError = message` (does not clear `verdict` or `lastFetch`) | none |
| `.openUpdateURL` | none | if `verdict` is `.blocked` with a non-nil `updateURL`, calls the plugin's `openURL` closure; otherwise no effect |

The plugin only handles its own actions. Any action that `extractAction` returns `nil` for is ignored — the plugin's `reduce(...)` returns `nil` immediately.

The combination of `.forceFetch`'s cached-fallback behavior and `.fetch`'s cache-freshness gate is the basis for the plugin's offline tolerance: a launch on a flaky network still yields a verdict (cached) and an error indicator (`fetchError`), without leaving the UI stuck on `.unknown`.

## Verdict evaluation rules

`KillswitchVerdict.evaluate(_:against:)` is fail-open: any unparseable input yields `.allowed`. Checks run in this fixed order, returning `.blocked(...)` on the first match:

1. **Current version parse.** If `currentVersionString` cannot be parsed as a `SemanticVersion`, return `.allowed` immediately.
2. **Minimum supported version.** If `config.minimumSupportedVersion` parses and `currentVersion < minVersion`, return `.blocked(...)`.
3. **Explicit blocked versions.** Iterate `config.blockedVersions`. If any entry parses and equals `currentVersion`, return `.blocked(...)`.
4. **Blocked ranges.** Iterate `config.blockedRanges`. If any entry parses as a `VersionRange` and contains `currentVersion`, return `.blocked(...)`.
5. **Otherwise** return `.allowed`.

A blocked verdict carries the config's `blockedTitle`, `blockedMessage`, and `updateURL` (parsed via `URL(string:)`) regardless of which check matched.

## Remote config JSON shape

`KillswitchConfig` derives its `Codable` conformance from synthesized keys, so the JSON keys match the property names. A representative file:

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

## See Also

- <doc:HowToAddAVersionKillswitch>
- <doc:PluginArchitecture>
