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

## Bulk Deletion

Each `cards[id] = nil` shifts the storage array's tail and reindexes the shifted entries — O(tail) per delete, so a loop of k subscript deletes costs O(n·k). To delete many entities at once, use `remove(ids:)` (when you have the IDs) or `removeAll(where:)` (when you have a predicate) instead: both remove everything in a single pass with one index rebuild, record the same deletions, and cancel pending upserts exactly like the subscript.

```swift
cards.remove(ids: selection)          // One pass, not a subscript loop
cards.removeAll { $0.isArchived }
```

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

### reconcile vs merge

The two answer different questions:

| | `merge(from:shouldReplace:)` | `reconcile(with:preserving:removingMissing:)` |
|---|---|---|
| Stance | Keep everything, absorb what's new | Storage is authoritative **except** where you say otherwise |
| Removes rows | Never | When `removingMissing` and the ID isn't preserved |
| Conflicts | Your closure decides, per pair | Storage wins unless the ID is preserved |

`reconcile` is what lets a remote edit or a remote deletion surface mid-session rather than waiting for the next launch. `preserving` is the caller's list of IDs that carry unflushed local intent; the store's own un-drained `changes` are folded in automatically, so a pending local deletion is never resurrected even when `preserving` is empty.

```swift
cards.reconcile(with: EntityStore(rowsFromDisk), preserving: dirtyIDs, removingMissing: true)
```

Like `merge`, it records no changes — every value it writes or removes already reflects what is in storage, so recording them would echo each remote change straight back as a local write.

Most apps never call this directly; `PersistenceCoordinator.rehydrate(into:)` does, and computes `preserving` for you.

## restore(from:)

`restore(from:)` replaces all entities with those from the source store while recording the diff as changes for persistence. Used by undo/redo (see <doc:UndoRedo>).

- **Deletions** — IDs in self but absent from source
- **Upserts** — IDs that are new or whose values differ
- **Unchanged** — identical values produce no change records
