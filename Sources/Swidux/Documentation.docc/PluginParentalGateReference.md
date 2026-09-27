# SwiduxParentalGate Reference

API surface for the `SwiduxParentalGate` library — a domain plugin that guards actions behind a math challenge.

## Overview

`SwiduxParentalGate` ships as a separate library target alongside `Swidux`. It provides a single domain plugin (`ParentalGatePlugin`), a state slice, an action enum, and a pluggable challenge generator. For task-oriented integration, see <doc:HowToAddAParentalGate>. For the underlying plugin contract, see <doc:PluginArchitecture>.

## Library target

Add the `SwiduxParentalGate` product as a target dependency, then import it where you wire the store and present the gate sheet:

```swift
import SwiduxParentalGate
```

The `Swidux` package vends each plugin as its own library product (`SwiduxParentalGate`, `SwiduxKillswitch`, `SwiduxPaywall`, and so on) alongside core `Swidux`. Pull in only what you use.

## Types

### ParentalGatePlugin

A `MainActor`-bound domain plugin generic over the host app's root state and action types.

```swift
@MainActor
public struct ParentalGatePlugin<RootState, RootAction>: SwiduxPlugin {
    public typealias State = RootState
    public typealias Action = RootAction

    public init(
        state: WritableKeyPath<RootState, ParentalGateState>,
        action toRootAction: @escaping @Sendable (ParentalGateAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> ParentalGateAction?,
        challengeSource: ParentalChallengeSource = .standard,
        attemptLimit: Int = 3,
        cooldown: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() },
        keyValueStore: (any KeyValueStore)? = nil
    )

    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>?
}
```

The three wiring closures follow the standard domain-plugin shape described in <doc:PluginArchitecture>: a keypath into the host's state, a lifter from local to root action, and an extractor from root to local action. The rest tune the rate limit:

- `attemptLimit` — consecutive wrong answers before a cooldown starts. Clamped to at least 1.
- `cooldown` — how long every answer is refused once the limit is reached. Clamped to at least zero.
- `now` — the wall-clock read that stamps `cooldownUntil`. Inject a fixed or movable clock in tests.
- `keyValueStore` — where the attempt count and cooldown deadline are persisted. Without one, the limit is **per process**: force-quitting the app and relaunching it starts over with no attempts counted and no cooldown. See <doc:PluginParentalGateReference#Rate-limit>.

### ParentalGateState

The state slice the plugin owns.

```swift
public struct ParentalGateState: Sendable, Equatable {
    public var pendingReason: String?
    public var challenge: MathChallenge?
    public var attempts: Int
    public var passedReasons: Set<String>
    public var cooldownUntil: Date?

    public init(
        pendingReason: String? = nil,
        challenge: MathChallenge? = nil,
        attempts: Int = 0,
        passedReasons: Set<String> = [],
        cooldownUntil: Date? = nil
    )

    public static func hydrated(from store: any KeyValueStore) -> ParentalGateState
}
```

- `pendingReason` — non-`nil` while a challenge is active. Drives sheet presentation.
- `challenge` — the currently-presented arithmetic problem.
- `attempts` — count of incorrect submissions since the last success or cooldown; preserved when reopening the gate.
- `passedReasons` — reasons already cleared this session (see action semantics below).
- `cooldownUntil` — while non-`nil`, every answer is refused. Survives `.dismiss` and `.request`. Disable the submit control and show a countdown to it.
- `hydrated(from:)` — the initial state for a plugin constructed with `keyValueStore:`: carries the persisted `attempts` and `cooldownUntil`, and nothing else.

### ParentalGateAction

```swift
public enum ParentalGateAction: Sendable {
    case request(reason: String)
    case dismiss
    case regenerateChallenge
    case submitAnswer(Int)
    case answerAccepted(reason: String)
    case answerRejected
    case cooldownExpired
}
```

### MathChallenge

```swift
public struct MathChallenge: Sendable, Equatable {
    public let left: Int
    public let right: Int
    public let op: Op

    public init(left: Int, right: Int, op: Op)

    public var expected: Int

    public enum Op: String, Sendable, CaseIterable {
        case plus, minus, times

        public var symbol: String  // "+", "−", "×"
    }
}
```

`expected` computes the correct answer from `left`, `right`, and `op`. `Op.symbol` returns a display-friendly Unicode glyph (minus sign U+2212, multiplication sign U+00D7).

### ParentalChallengeSource

A value-type holder for a challenge generator closure.

```swift
public struct ParentalChallengeSource: Sendable {
    public var generate: @Sendable () -> MathChallenge

    public init(generate: @escaping @Sendable () -> MathChallenge)

    public static let standard: ParentalChallengeSource
    public static func fixed(_ challenge: MathChallenge) -> ParentalChallengeSource
}
```

- `ParentalChallengeSource.standard` — random, age-appropriate challenges. Plus adds two operands in 10–20. Minus subtracts a right operand in 1 to one less than the left from a left operand in 20–40, so the answer is always positive. Times multiplies two operands in 3–9.
- `ParentalChallengeSource.fixed(_:)` — always returns the supplied challenge. Use this in tests.

## Action semantics

Each `ParentalGateAction` case mutates the state slice as follows:

- **`.request(reason:)`** — If `passedReasons` already contains `reason`, the plugin returns an effect that immediately dispatches `.answerAccepted(reason:)` and leaves `pendingReason` unchanged. Otherwise, it sets `pendingReason`, generates a fresh `challenge`, and preserves the attempt count. During a cooldown it also re-arms the timer that dispatches `.cooldownExpired`.
- **`.dismiss`** — Clears `pendingReason` and `challenge`. Preserves attempts, cooldown, and `passedReasons`.
- **`.regenerateChallenge`** — Replaces `challenge` with a freshly generated one. Useful for a "new question" button.
- **`.submitAnswer(Int)`** — Validates against `challenge.expected` synchronously. A correct answer grants the pending reason and clears the challenge and attempts. A wrong answer increments attempts, generates a new challenge, and starts a cooldown at the limit. The returned effect dispatches the corresponding notification. No-op during cooldown or when no challenge is pending.
- **`.answerAccepted(reason:)`** — Notifies the host of an already-granted reason; does not mutate gate state.
- **`.answerRejected`** — Notifies the host of an already-counted wrong answer; does not mutate gate state.
- **`.cooldownExpired`** — Clears the cooldown and issues a fresh challenge if the deadline has elapsed. Early (a stale timer from an earlier cooldown), it re-arms for the time remaining instead, so it cannot clear a newer cooldown and cannot be lost.

### Rate limit

The attempt limit is enforced in the reducer, synchronously, so rapid submissions cannot race it, and reopening the gate cannot reset it. Two things sit outside the reducer, and each needs its own answer: the process, and the clock.

**Relaunching.** State is in memory. Pass a `KeyValueStore` to the plugin and hydrate the slice from the same store, and the attempt count and cooldown survive a force-quit:

```swift
let kv = UserDefaultsKeyValueStore()
let parentalGatePlugin = ParentalGatePlugin<AppState, AppAction>(
    state: \.parentalGate,
    action: AppAction.parentalGate,
    extractAction: { if case .parentalGate(let a) = $0 { return a }; return nil },
    keyValueStore: kv
)
var initialState = AppState()
initialState.parentalGate = .hydrated(from: kv)
```

The write happens in an effect as soon as either value changes. Without a store the limit is per process. Neither makes it a security boundary: deleting the app, or its data, clears the store too. See <doc:SecurityPosture>.

**The device clock.** `cooldownUntil` is a wall-clock `Date`, because it has to survive a relaunch and drive a countdown. The plugin does not compare against it directly, though. The first time a process sees a deadline it pins it to the monotonic clock, and from then on moving the device clock neither skips the cooldown nor extends it. A deadline seen fresh (hydrated after a relaunch, or set by your own code) is first held to at most one `cooldown` from now, so a clock moved backward, or an edited store, cannot lock the gate for longer. Across a relaunch the persisted deadline is only as good as the wall clock: moving it forward before relaunching ends that cooldown early.

### Session-pass behavior

Once a reason is in `passedReasons`, subsequent `.request(reason:)` calls for that same reason short-circuit: the plugin dispatches `.answerAccepted(reason:)` immediately without presenting a challenge. This is intentional — it lets feature reducers re-issue the gate request after re-entering a flow, while only prompting the user once per session.

`passedReasons` is a `Set<String>`, so use distinct reason keys per gated action when you want them to clear independently. To force a re-challenge, mutate `state.parentalGate.passedReasons` from your own reducer (for example, in response to an `app/lock` action).

## Customizing the challenge

`ParentalChallengeSource` is a single-closure container. To plug in your own generator — different operand ranges, alternative operations, locale-specific phrasing of operands — construct one directly:

```swift
let source = ParentalChallengeSource {
    let left = Int.random(in: 50...99)
    let right = Int.random(in: 50...99)
    return MathChallenge(left: left, right: right, op: .plus)
}

let plugin = ParentalGatePlugin<AppState, AppAction>(
    state: \.parentalGate,
    action: AppAction.parentalGate,
    extractAction: { if case .parentalGate(let a) = $0 { return a }; return nil },
    challengeSource: source
)
```

The generator runs synchronously each time the plugin needs a new challenge (on `.request`, `.regenerateChallenge`, wrong submissions, and cooldown expiry). Keep it cheap and pure — no I/O.

## See Also

- <doc:HowToAddAParentalGate>
- <doc:PluginArchitecture>
