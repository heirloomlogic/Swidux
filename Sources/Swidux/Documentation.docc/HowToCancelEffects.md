# Cancel Effects

Tag an effect with an identity so it can be cancelled later — by another effect, or imperatively from view code.

## Overview

Every effect the store runs is already cancelled on teardown: ``Store/cancelEffects()`` and the store's `deinit` cancel all in-flight effect tasks. That is enough for cleanup, but it is *all-or-nothing* — you cannot cancel one specific effect while others keep running.

Keyed cancellation adds that. You give an effect a **cancel id** with ``cancellable(id:cancelInFlight:_:)``, and later cancel every effect running under that id with the ``cancel(id:)`` effect or the imperative ``Store/cancel(id:)`` method. ``Effect`` carries cancellation metadata alongside its async operation. The store registers declared cancellation scopes synchronously before starting background work, so an immediate cancellation cannot race registration.

Reach for this when an effect outlives the action that started it: cancelling text-to-speech when the user skips, debouncing a search field, or tearing down a long-lived listener when a screen disappears.

## Choosing an id

A cancel id is any `Hashable & Sendable` value. Distinct ids are independent; effects sharing an id are cancelled together. A dedicated empty type reads well and can't collide with another feature's id:

```swift
private struct SearchID: Hashable, Sendable {}
private struct SpeechID: Hashable, Sendable {}
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

Cancellation is cooperative: a stream or service must observe cancellation to stop its work. Keyed effects also suppress sends after cancellation, so a service that returns a stale successful result cannot publish it.

## Report the cancellation with `onCancel`

Suppression covers *every* send after cancellation, including one from a `catch` block. A plain `Effect` can clear its own in-flight flag that way; a keyed one cannot, because the store can't tell a cleanup action from a stale result. Name the cleanup action with `onCancel:` instead, and the store dispatches it for you:

```swift
case .search(let query):
    state.isSearching = true
    return cancellable(id: SearchID(), onCancel: .searchCancelled) { send in
        await send(.results(try await api.search(query)))
    }

case .searchCancelled:
    state.isSearching = false
```

The store dispatches `onCancel` when ``cancel(id:)``, ``Store/cancel(id:)``, or ``Store/cancelEffects()`` cancels the effect while it is still running — at once from view code, or right after the current action when a reducer returns ``cancel(id:)``. It is dispatched once, and never for an effect that already finished. Two cases don't dispatch it:

- A `cancelInFlight` effect replacing this one. The action that started the replacement is already setting that state, and a late `.searchCancelled` would clear `isSearching` while the new search runs.
- A scope nested inside another scope that is cancelled at the same time. The outer scope's `onCancel` covers both.

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

Ids with nothing running are ignored, so it is always safe to call. No reducer runs here that could reset an in-flight flag, so give the effect an `onCancel:` action if it sets one.

## What it does not replace

Keyed cancellation is not a substitute for resource cleanup. An effect holding a file handle, a network connection, or an `AsyncStream` continuation should still release it — use `withTaskCancellationHandler` or a `defer`. Cancellation requests that the task stop; it does not close what the task opened.

Effects that terminate on their own (a `for await` loop whose stream finishes) need no id at all. Only reach for a cancel id when something *else* has to stop the effect early.

## Constructing and lifting effects

Create ordinary work with `Effect { send in ... }`. When a feature returns an effect with its own action type, lift it with `map`:

```swift
return featureEffect.map(AppAction.feature)
```

`map` preserves cancellation metadata. Wrapping another effect inside a new operation hides that declaration from the store until the inner effect is invoked. Such dynamically invoked scopes become active on invocation; cancelling an ID does not prohibit future scopes with that ID. Scope registrations are removed when their operation finishes, including when it throws. Cancellation keys are not retained as a history of past commands.

## Nested scopes

A scope invoked inside another effect runs as its own child task, so cancelling its id cancels that scope alone. The effect hosting it carries on — the invocation throws `CancellationError`, which the host can catch — and so do the host's other scopes, whatever their ids. That is what keeps a long-lived listener alive when one of the fetches it starts is abandoned:

```swift
case .startListening:
    return Effect { send in
        for await event in events {
            let fetch: Effect<AppAction> = cancellable(id: FetchID(), cancelInFlight: true) { send in
                await send(.fetched(try await api.fetch(event)))
            }
            try? await fetch(send)  // `store.cancel(id: FetchID())` ends this fetch, not the loop
        }
    }
```

Cancelling the host still cancels every scope inside it. `cancelInFlight` on a nested scope replaces any other scope running under the same id, including a concurrent one in the same host (for example in a task group), but never a scope it is nested in.
