# KeyValueStore

Persist scalar preferences like theme, sort order, or last-seen version — testably, with type-safe keys.

## Overview

``KeyValueStore`` is a small protocol for one-shot scalar values that don't fit
the ``EntityStore`` model. Three implementations ship:

- ``UserDefaultsKeyValueStore`` — production, backed by any `UserDefaults` suite
- ``KeychainKeyValueStore`` — production, backed by the system Keychain (survives reinstall)
- ``InMemoryKeyValueStore`` — tests, dictionary-backed, reference semantics

Inject through your `Environment`, hydrate state at startup, and write from
effects. Reducers stay pure.

```swift
public protocol KeyValueStore: Sendable {
    func value<Value>(_ key: KVKey<Value>) -> Value?
    func setValue<Value>(_ value: Value?, for key: KVKey<Value>)
    func removeValue<Value>(for key: KVKey<Value>)
    func contains<Value>(_ key: KVKey<Value>) -> Bool
}
```

All values are JSON-encoded as `Data`. Reads and writes go through ``KVKey``,
which pairs a backing-store name with its `Codable` value type at compile time.

## When to Use What

| Need | Use |
|---|---|
| Collection of identifiable entities (decks, cards, sessions) | ``EntityStore`` + ``PersistencePlugin`` |
| Scalar preference (theme, sort order, last-seen version) | ``KeyValueStore`` (UserDefaults) |
| Anonymous device identity that must survive reinstall | ``KeyValueStore`` (Keychain) |

`EntityStore` is for many-of-a-kind data with change tracking and batched
writes. `KeyValueStore` is for one-of-a-kind values that you read once at
startup and overwrite on change.

### UserDefaults vs Keychain

| | ``UserDefaultsKeyValueStore`` | ``KeychainKeyValueStore`` |
|---|---|---|
| Survives reinstall? | No | Yes (this-device-only by default) |
| Backup / device migration | Included | Excluded with default accessibility |
| Throughput | Fast (in-memory cache) | Slower (system call) |
| Visible to other apps? | No (per app/group) | Optionally (App Groups via `accessGroup:`) |
| Best for | Theme, sort order, feature toggles, last-seen version | Anonymous device ID, opaque tokens |

The Keychain costs more per access — hydrate once at launch and observe state
afterward, never read inside a reducer.

### macOS sandbox & entitlements

`KeychainKeyValueStore` uses the data-protection keychain, so it never raises
a user prompt — no "Always Allow / Deny" dialog, no locked-keychain prompt, no
Touch ID / Face ID challenge.

> Tip: A *sandboxed* macOS app still needs a keychain entitlement, even when
> not sharing items across an access group. Xcode supplies an
> `application-identifier` automatically for provisioning-profile–signed
> builds; otherwise add an explicit `keychain-access-groups` entry:
>
> ```xml
> <key>keychain-access-groups</key>
> <array>
>     <string>$(AppIdentifierPrefix)com.example.myapp</string>
> </array>
> ```
>
> Without it, the first `setValue` fails with `errSecMissingEntitlement`
> (`OSStatus` −34018). This is a build/signing condition, not a runtime
> prompt. iOS / iPadOS / tvOS / watchOS need no extra entitlement.

Encryption, accessibility, iCloud-sync exclusion, and backup exclusion are
identical whichever entitlement you use — the access group only controls
*which of your own apps* can read an item, never third parties or the cloud.
For a private device ID, in order of strictness:

1. **Most private:** profile-signed build + `accessGroup: nil`, relying on the
   implicit `application-identifier` group. No other app — even same-team —
   can be entitled to it. Mirrors the iOS default; zero sharing surface.
2. **Practically equivalent:** a `keychain-access-groups` array whose only
   entry is the team-prefixed bundle id (the snippet above). Use when a
   profile-signed build isn't available (unsigned local / CI dev). Only delta:
   a same-team app you sign could also declare that string.
3. **Intentional sharing only:** a shared group string. The *first* element
   becomes the default group for new items — never put a shared group first
   for private data.

## Device-Identity Pattern

The original motivation for ``KeychainKeyValueStore`` was apps without user
auth that still want stable identity for analytics. Mint a UUID once with the
``KeyValueStore/deviceIdentity(key:)`` helper, hydrate into `AppState` at launch,
and feed it to `AnalyticsIdentity`. The *same* `deviceID` is also the stable
feature-flag bucketing identity (the plugin's `deviceIDKeyPath`), so analytics
and A/B exposure share one identity:

```swift
// `KVKey.deviceID` and `deviceIdentity()` ship with Swidux.

// In Store.configured(), before constructing the store:
let kv = KeychainKeyValueStore(service: "com.example.myapp")
let deviceID = kv.deviceIdentity()   // reads, or mints-and-persists, a stable UUID

let initialState = AppState(deviceID: deviceID, /* … */)
```

Then in the analytics plugin wiring:

```swift
AnalyticsPlugin(
    service: analytics,
    identity: AnalyticsIdentity(userID: \.deviceID, properties: { _ in [:] }),
    // …
)
```

The closure-based `userID` keypath runs on every dispatch, so the value
**must** live in state — never call into the Keychain from the closure. Hydrate
once; observe state.

## Type-safe Keys

Declare each key once on ``KVKey`` so the value type travels with the name —
no magic strings at call sites:

```swift
extension KVKey where Value == Theme {
    static let theme = KVKey<Theme>("theme")
}

extension KVKey where Value == SortOrder {
    static let sortOrder = KVKey<SortOrder>("sortOrder")
}

extension KVKey where Value == String {
    static let lastSeenVersion = KVKey<String>("lastSeenVersion")
}
```

Then read and write through static-member literals. The compiler enforces
that the value type matches what you declared:

```swift
let theme = store.value(.theme) ?? .system            // Theme?
store.setValue(theme, for: .theme)
store.setValue(.alphabetical, for: .sortOrder)
store.removeValue(for: .lastSeenVersion)
```

A typo or wrong type produces a compile error, not a silent miss at runtime.
Centralizing keys on ``KVKey`` also gives you autocomplete and a single place
to audit your preference surface.

## Wiring

### 1. Add to your environment

```swift
struct AppEnvironment: Sendable {
    var keyValue: any KeyValueStore

    static func live() -> AppEnvironment {
        AppEnvironment(keyValue: UserDefaultsKeyValueStore())
    }
}
```

### 2. Hydrate at startup

Read once into the initial state — never read mid-cycle from a reducer.

```swift
extension AppState {
    static func hydrated(from store: any KeyValueStore) -> AppState {
        AppState(
            theme: store.value(.theme) ?? .system,
            sortOrder: store.value(.sortOrder) ?? .alphabetical,
            lastSeenVersion: store.value(.lastSeenVersion)
        )
    }
}

let env = AppEnvironment.live()
let store = AppStore.configured(state: .hydrated(from: env.keyValue), environment: env)
```

### 3. Write from an effect

Mutate state in the reducer, return an effect that writes the value:

```swift
case .themeChanged(let theme):
    state.theme = theme
    return { @Sendable _ in
        environment.keyValue.setValue(theme, for: .theme)
    }
```

No `try?`, no `do/catch`. ``KeyValueStore/setValue(_:for:)`` does not throw —
encoder errors are programmer mistakes (e.g. `Float.nan`), so the store logs
them and triggers `assertionFailure` in DEBUG instead of forcing every effect
to handle an `Error` it can't act on.

## Testing

Inject ``InMemoryKeyValueStore`` and assert against the same instance:

```swift
@Test
@MainActor
func themeChangePersists() async throws {
    let prefs = InMemoryKeyValueStore()
    let env = AppEnvironment(keyValue: prefs)
    let store = AppStore.configured(state: AppState(), environment: env)

    try await confirmation(expectedCount: 1) { confirm in
        store.send(.themeChanged(.dark))

        for _ in 0..<50 {
            if prefs.value(.theme) == .dark {
                confirm()
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // Simulate a relaunch.
    let rehydrated = AppState.hydrated(from: prefs)
    #expect(rehydrated.theme == .dark)
}
```

Tests touching real `UserDefaults` should use a fresh per-test suite and tear
it down explicitly:

```swift
let suiteName = "myapp.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }

let store = UserDefaultsKeyValueStore(suite: defaults)
```

## Reads Are For Hydration

> Important: Reading from ``KeyValueStore`` mid-cycle (inside a reducer) is an
> anti-pattern. Reducers must be pure and synchronous; reads happen once at
> `AppState` construction. After hydration, the value lives in state and
> downstream code observes state, not the store.

`UserDefaults` itself is thread-safe, but a reducer reading while an effect
writes creates ordering ambiguity. Hydrate, observe state, write through
effects — that's the discipline.

## Failure Modes

- **Missing key** — ``KeyValueStore/value(_:)`` returns `nil`. Provide a
  default at the call site.
- **Decode failure** — returns `nil` and logs through `os.Logger`
  (subsystem `"swidux"`, category `"kvstore"`). On startup, behaves identically
  to first launch.
- **Encode failure** — logged at the same subsystem/category, then
  `assertionFailure` fires in DEBUG so the bug surfaces during development.
  Production builds log and continue; the in-memory state is unchanged. The
  API does not throw — there is no useful runtime recovery from inside an
  effect, and `try?` would just hide the problem.

## @AppStorage Interop

There is none, by design. ``UserDefaultsKeyValueStore`` writes JSON-encoded
`Data` blobs. SwiftUI's `@AppStorage` only observes native primitive types
(`Bool`, `Int`, `String`, `Double`, `URL`, raw `Data`). Two parallel
observation channels — Swidux state and `@AppStorage` — would drift.

Swidux state is the source of truth. Read once at hydration, then observe
state through the store.

## Schema Migration

Out of scope for ``KeyValueStore``. If a `Codable` shape changes
incompatibly, declare a new versioned key:

```swift
// before:
extension KVKey where Value == Theme {
    static let theme = KVKey<Theme>("theme")
}
// after a breaking shape change:
extension KVKey where Value == Theme {
    static let theme = KVKey<Theme>("theme.v2")
}
```

Old keys can be cleaned up at startup with ``KeyValueStore/removeValue(for:)``
(declare a tombstone ``KVKey`` of any value type — only the name is read).

## Topics

### Keys

- ``KVKey``

### Protocol

- ``KeyValueStore``

### Implementations

- ``UserDefaultsKeyValueStore``
- ``KeychainKeyValueStore``
- ``InMemoryKeyValueStore``
