# Add a Parental Gate

Gate sensitive actions — purchases, settings changes, leaving a kid-mode area — behind a math challenge.

## Overview

When you finish, your app will:

- Hold a `ParentalGateState` slice in `AppState` and a `parentalGate` action case in `AppAction`.
- Run `ParentalGatePlugin` as part of the store's plugin host.
- Present a math-challenge sheet whenever a feature requests a gate, and resume the original action once the user solves it.

For the API surface, see <doc:PluginParentalGateReference>. For how domain plugins fit into the dispatch lifecycle, see <doc:PluginArchitecture>.

## Before you start

This guide assumes you already have a Swidux app wired with `AppState`, `AppAction`, an `AppReducer`, and a `Store.configured()` factory. If you don't, start with the getting-started material and come back here.

## Step 1: Add the dependency

The parental-gate plugin ships as a separate library product. Add it to your target's dependencies:

```swift
// Package.swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Swidux", package: "Swidux"),
        .product(name: "SwiduxParentalGate", package: "Swidux"),
    ]
)
```

## Step 2: Add state and actions

Nest a `ParentalGateState` slice on your root state, and add an action case that wraps `ParentalGateAction`.

```swift
// AppState.swift
import SwiduxParentalGate

@Swidux
nonisolated struct AppState: Equatable, Sendable {
    @Slice var parentalGate: ParentalGateState = .init()
    // … other slices
}

// AppAction.swift
enum AppAction: Sendable {
    case parentalGate(ParentalGateAction)
    // … other cases
}
```

The plugin owns the parental-gate slice end-to-end, so the root reducer just falls through:

```swift
// AppReducer.swift
case .parentalGate:
    return nil
```

## Step 3: Wire the plugin

Construct `ParentalGatePlugin` inside `Store.configured()` and register it with the plugin host. Use `ParentalChallengeSource.standard` for production:

```swift
// AppStore.swift
let parentalGatePlugin = ParentalGatePlugin<AppState, AppAction>(
    state: \.parentalGate,
    action: AppAction.parentalGate,
    extractAction: { if case .parentalGate(let a) = $0 { return a }; return nil },
    challengeSource: .standard
)

let plugins = PluginHost<AppState, AppAction>()
plugins.register(undoPlugin)
plugins.register(persistencePlugin)
plugins.register(parentalGatePlugin)
```

Domain plugins use only the `reduce` hook, so registration order relative to other domain plugins rarely matters.

## Step 4: Gate an action

Pick a stable reason key per gated action (for example `"purchase"`, `"settings"`, `"exit-kid-mode"`). In a view or feature reducer, check `passedReasons` before performing the work:

```swift
Button("Buy gems") {
    if store.parentalGate.passedReasons.contains("purchase") {
        store.send(.shop(.buyGems))
    } else {
        store.send(.parentalGate(.request(reason: "purchase")))
    }
}
```

To resume the original action automatically once the user solves the challenge, listen for `.answerAccepted(reason:)` in the relevant feature reducer and re-dispatch:

```swift
// ShopReducer.swift
func reduce(
    state: inout AppState,
    action: AppAction,
    environment: AppEnvironment
) -> Effect? {
    switch action {
    case .parentalGate(.answerAccepted(let reason)) where reason == "purchase":
        return { send in await send(.shop(.buyGems)) }
    // …
    }
}
```

This pattern keeps the gate logic local to the feature it protects: the gate just emits `answerAccepted`, and each feature decides what — if anything — to resume.

## Step 5: Present the challenge sheet

Drive sheet presentation off `pendingReason`. Bind text input to a local `@State` for the typed answer, dispatch `ParentalGateAction.submitAnswer(_:)` on confirm, and `ParentalGateAction.regenerateChallenge` for a "new question" button.

```swift
struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        // … your app UI
            .sheet(isPresented: Binding(
                get: { store.parentalGate.pendingReason != nil },
                set: { if !$0 { store.send(.parentalGate(.dismiss)) } }
            )) {
                ParentalGateSheet()
            }
    }
}

struct ParentalGateSheet: View {
    @Environment(AppStore.self) private var store
    @State private var answer: String = ""

    var body: some View {
        VStack(spacing: 16) {
            if let challenge = store.parentalGate.challenge {
                Text("\(challenge.left) \(challenge.op.symbol) \(challenge.right) = ?")
                    .font(.title)

                TextField("Answer", text: $answer)
                    .keyboardType(.numberPad)

                HStack {
                    Button("New question") {
                        store.send(.parentalGate(.regenerateChallenge))
                        answer = ""
                    }
                    Button("Submit") {
                        if let value = Int(answer) {
                            store.send(.parentalGate(.submitAnswer(value)))
                        }
                        answer = ""
                    }
                }
            }
        }
        .padding()
    }
}
```

When the user submits a wrong answer, the plugin increments `attempts` and regenerates the challenge automatically, so the sheet just re-renders with the new operands.

## Reasons that should be passed once vs. always re-challenged

The auto-pass behavior of `ParentalGateAction.request(reason:)` (see <doc:PluginParentalGateReference>) is a design choice: once a reason is in `passedReasons`, future `.request` calls for it short-circuit. That's the right default for low-stakes gates inside a single session — the user shouldn't solve the same problem every time they tap the same button.

For higher-stakes gates that should always re-challenge, use a fresh reason key each time:

```swift
store.send(.parentalGate(.request(reason: "purchase-\(UUID().uuidString)")))
```

Or, more usefully, clear the relevant entries from `passedReasons` at meaningful boundaries — app launch, session timeout, or returning from background. Mutate the set directly from your own reducer:

```swift
case .app(.didEnterBackground):
    state.parentalGate.passedReasons.removeAll()
    return nil
```

## Testing

For deterministic tests, swap the standard generator for `ParentalChallengeSource.fixed(_:)`:

```swift
@MainActor
@Test func correctAnswerAcceptsAndPasses() async throws {
    let challenge = MathChallenge(left: 2, right: 3, op: .plus)  // expected = 5
    let plugin = ParentalGatePlugin<AppState, AppAction>(
        state: \.parentalGate,
        action: AppAction.parentalGate,
        extractAction: { if case .parentalGate(let a) = $0 { return a }; return nil },
        challengeSource: .fixed(challenge)
    )

    var state = AppState()
    state.parentalGate.pendingReason = "settings"
    state.parentalGate.challenge = challenge

    let effect = plugin.reduce(state: &state, action: .parentalGate(.submitAnswer(5)))
    let effect = try #require(effect)

    var dispatched: [AppAction] = []
    await effect { dispatched.append($0) }

    if case .parentalGate(.answerAccepted(let reason)) = dispatched.first {
        #expect(reason == "settings")
    } else {
        Issue.record("expected answerAccepted, got \(dispatched)")
    }
}
```

The `SwiduxParentalGateTests` target in this package uses the same pattern — a fixed challenge plus a small test root state — and is a good reference when wiring tests for your own gated features.

## See Also

- <doc:PluginParentalGateReference>
- <doc:PluginArchitecture>
