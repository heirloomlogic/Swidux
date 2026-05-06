# SwiduxParentalGate Reference

API surface for the `SwiduxParentalGate` library — a domain plugin that guards actions behind a math challenge.

## Overview

`SwiduxParentalGate` ships as a separate library target alongside `Swidux`. It provides a single domain plugin (`ParentalGatePlugin`), a state slice, an action enum, and a pluggable challenge generator. For task-oriented integration, see <doc:HowToAddAParentalGate>. For the underlying plugin contract, see <doc:PluginArchitecture>.

## Library target

Add the `SwiduxParentalGate` product as a target dependency, then import it where you wire the store and present the gate sheet:

```swift
import SwiduxParentalGate
```

The package vends three library products: `Swidux`, `SwiduxKillswitch`, `SwiduxParentalGate`, and `SwiduxPaywall`. Pull in only what you use.

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
        challengeSource: ParentalChallengeSource = .standard
    )

    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>?
}
```

The three wiring closures follow the standard domain-plugin shape described in <doc:PluginArchitecture>: a keypath into the host's state, a lifter from local to root action, and an extractor from root to local action.

### ParentalGateState

The state slice the plugin owns.

```swift
public struct ParentalGateState: Sendable, Equatable {
    public var pendingReason: String?
    public var challenge: MathChallenge?
    public var attempts: Int
    public var passedReasons: Set<String>

    public init(
        pendingReason: String? = nil,
        challenge: MathChallenge? = nil,
        attempts: Int = 0,
        passedReasons: Set<String> = []
    )
}
```

- `pendingReason` — non-`nil` while a challenge is active. Drives sheet presentation.
- `challenge` — the currently-presented arithmetic problem.
- `attempts` — count of incorrect submissions against the current challenge.
- `passedReasons` — reasons already cleared this session (see action semantics below).

### ParentalGateAction

```swift
public enum ParentalGateAction: Sendable {
    case request(reason: String)
    case dismiss
    case regenerateChallenge
    case submitAnswer(Int)
    case answerAccepted(reason: String)
    case answerRejected
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

- `ParentalChallengeSource.standard` — random, age-appropriate challenges. Plus and minus use operands in the 10–40 range; times uses 3–9. Subtraction is always non-negative.
- `ParentalChallengeSource.fixed(_:)` — always returns the supplied challenge. Use this in tests.

## Action semantics

Each `ParentalGateAction` case mutates the state slice as follows:

- **`.request(reason:)`** — If `passedReasons` already contains `reason`, the plugin returns an effect that immediately dispatches `.answerAccepted(reason:)` and leaves `pendingReason` unchanged. Otherwise, it sets `pendingReason`, generates a fresh `challenge`, and resets `attempts` to `0`.
- **`.dismiss`** — Clears `pendingReason`, `challenge`, and `attempts`. Does not modify `passedReasons`.
- **`.regenerateChallenge`** — Replaces `challenge` with a freshly generated one. Useful for a "new question" button.
- **`.submitAnswer(Int)`** — Compares against `challenge.expected`. Returns an effect that dispatches either `.answerAccepted(reason:)` (with the current `pendingReason`) or `.answerRejected`. No-op if `challenge` or `pendingReason` is `nil`.
- **`.answerAccepted(reason:)`** — Inserts `reason` into `passedReasons`, clears `pendingReason`, `challenge`, and `attempts`.
- **`.answerRejected`** — Increments `attempts` and regenerates `challenge` so the user faces a new problem.

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

The generator runs synchronously each time the plugin needs a new challenge (on `.request`, `.regenerateChallenge`, and `.answerRejected`). Keep it cheap and pure — no I/O.

## See Also

- <doc:HowToAddAParentalGate>
- <doc:PluginArchitecture>
