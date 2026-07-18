# Cancel Effects

Tag an effect with an identity so it can be cancelled later — by another effect, or imperatively from view code.

## Overview

Every effect the store runs is already cancelled on teardown: ``Store/cancelEffects()`` and the store's `deinit` cancel all in-flight effect tasks. That is enough for cleanup, but it is *all-or-nothing* — you cannot cancel one specific effect while others keep running.

Keyed cancellation adds that. You give an effect a **cancel id** with ``cancellable(id:cancelInFlight:_:)``, and later cancel every effect running under that id with the ``cancel(id:)`` effect or the imperative ``Store/cancel(id:)`` method. Identity lives outside the ``Effect`` type — it is still a plain closure — so nothing about reducer signatures changes.

Reach for this when an effect outlives the action that started it: cancelling text-to-speech when the user skips, debouncing a search field, or tearing down a long-lived listener when a screen disappears.

## Choosing an id

A cancel id is any `Hashable & Sendable` value. Distinct ids are independent; effects sharing an id are cancelled together. A dedicated empty type reads well and can't collide with another feature's id:

```swift
private enum SearchID: Hashable, Sendable {}
private enum SpeechID: Hashable, Sendable {}
```

Strings and enums work too — pick whatever is unambiguous in your domain.

## Cancel from inside a reducer

Return ``cancellable(id:cancelInFlight:_:)`` to tag the work, and ``cancel(id:)`` to stop it:

```swift
case .startSpeaking(let text):
    return cancellable(id: SpeechID()) { send in
        for await word in speech.speak(text) {
            await send(.spokeWord(word))
        }
    }

case .skip:
    // Stop any in-flight speech immediately.
    return cancel(id: SpeechID())
```

When the speaking effect is cancelled, its `for await` loop ends at the next suspension point, exactly as it would on teardown.

## Debounce with `cancelInFlight`

Passing `cancelInFlight: true` cancels any effect already running under the id *before* starting the new one — the whole of debounce in one line:

```swift
case .queryChanged(let query):
    return cancellable(id: SearchID(), cancelInFlight: true) { send in
        try await Task.sleep(for: .milliseconds(300))
        let results = try await api.search(query)
        await send(.results(results))
    }
```

Each keystroke re-dispatches `.queryChanged`; the new effect cancels the previous sleeping one, so only the last query in a burst reaches the network.

## Cancel from view or scene code

When there is no reducer action to hang the cancellation on — a screen disappearing, a sheet dismissing — call ``Store/cancel(id:)`` directly:

```swift
.onDisappear {
    store.cancel(id: SearchID())
}
```

Ids with nothing running are ignored, so it is always safe to call.

## What it does not replace

Keyed cancellation is not a substitute for resource cleanup. An effect holding a file handle, a network connection, or an `AsyncStream` continuation should still release it — use `withTaskCancellationHandler` or a `defer`. Cancellation ends the task; it does not close what the task opened.

Effects that terminate on their own (a `for await` loop whose stream finishes) need no id at all. Only reach for a cancel id when something *else* has to stop the effect early.
