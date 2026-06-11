# EntityStore

An ordered, keyed collection with built-in change tracking.

## Overview

``EntityStore`` works like a dictionary with insertion-order iteration. Entities must conform to `Identifiable & Equatable & Sendable` with `UUID` as the ID type.

```swift
var cards = EntityStore<Card>()

cards[card.id] = card                      // Insert or update — recorded
cards.modify(card.id) { $0.title = "New" } // In-place — recorded only if value changes
cards[card.id] = nil                       // Delete — recorded

let card = cards[cardID]                   // O(1) lookup
let all  = cards.values                    // Insertion-ordered array

cards.sort { $0.sortIndex < $1.sortIndex } // Only marks moved entities
cards.removeAll { $0.isArchived }          // Rebuilds index in one pass
```

Every mutation is tracked in a ``ChangeSet`` that the middleware drains after each reducer call.

## Merging (Re-hydration)

Replacing an ``EntityStore`` after startup destroys any in-memory state that was loaded lazily after initial hydration. Use `merge(from:shouldReplace:)` instead — entities only in the other store are always added, and the closure decides whether an incoming value overwrites the current one:

```swift
// Absorb DB rows; take an incoming row only when the current one
// lacks lazily-computed data.
campaigns.merge(from: EntityStore(allFromDB)) { current, incoming in
    current.calculationState == nil && incoming.calculationState != nil
}
```

`merge` does not record changes — it has hydration semantics like `init(_:)`.

## restore(from:)

`restore(from:)` replaces all entities with those from the source store while recording the diff as changes for persistence. Used by undo/redo (see <doc:UndoRedo>).

- **Deletions** — IDs in self but absent from source
- **Upserts** — IDs that are new or whose values differ
- **Unchanged** — identical values produce no change records
