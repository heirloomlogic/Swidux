# Editing canonical entities

Keep editor drafts separate from current application state, then apply their changes as one local group.

``EntityEditSession`` compares each edited field's original value, current canonical value, and proposed value. It applies the group only if every field and association operation passes validation. A rejected group leaves current state unchanged and retains the complete draft, including its nonconflicting edits.

This is a synchronous, in-memory operation on the main actor. A successful `apply` does not mean the data reached disk. Use `EntityEditPersistence.commit(_:to:)` for a grouped local save; see <doc:PersistedAssociations> for declarations, ordering, and persistence setup. Cross-device convergence remains open in [issue #102](https://github.com/heirloomlogic/Swidux/issues/102).

State and entities must have value semantics. Use structs whose editable fields do not mutate shared reference storage. A session snapshot is an editor draft; application reads and association navigation use the current ``EntityStore`` collections.

```swift
import Foundation
import Swidux

struct Note: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var body: String
}

struct NotesState: Sendable {
    var notes = EntityStore<Note>()
}

@MainActor
func editTitle() throws {
    let note = Note(id: UUID(), title: "Old", body: "Original body")
    var state = NotesState(notes: EntityStore([note]))
    let session = EntityEditSession(state: state)
    try session.edit(
        Note.self, id: note.id, in: \NotesState.notes,
        field: \Note.title, named: "title", to: "Draft title")

    state.notes.modify(note.id) { $0.body = "Newer body" }
    let result = session.apply(to: &state)
    guard result.wasApplied else {
        // Present result.conflicts; the session still holds the draft.
        return
    }
    // On success, the title is "Draft title" and the body is "Newer body".
}
```

Field names identify conflicts for the caller. Use one name per property within a collection; aliases for the same property or duplicate names for different properties are rejected. Entity IDs cannot be edited. Association owner fields must be changed through association commands.

| Session edit | Current value | Outcome |
| --- | --- | --- |
| Changes `Old` to `Draft` | `Old` | Apply `Draft` |
| Changes `Old` to `Draft` | `Draft` | Already satisfied; no conflict |
| Changes `Old` to `Draft` | `New` | Reject the whole group |
| Leaves a field unchanged | Any current value | Preserve the current value |

Field conflicts contain the entity's ID and type, the field name, and typed original/current/proposed values. Read a value with `value(as:)`. A missing entity has its own conflict kind; it is different from an optional field whose current value is `nil`. Repeating a rejected apply checks the same draft against the latest state. Successful application and cancellation end the session.

``EntityAssociation`` describes a named relationship between parent and child collections through a child's optional parent-ID field. Declare every association used by the session in its catalog. Parent deletion checks the catalog's registered associations; a plain scalar foreign key outside the catalog has no association enforcement. Navigation resolves the current entities by ID. An unresolved parent ID remains on the child even when the parent cannot yet be resolved.

Removal and parent deletion each require an explicit policy:

| Policy | Remove child from association | Delete parent with associated children |
| --- | --- | --- |
| `detach` | Clear the owner ID and keep the child | Clear owner IDs and keep the children |
| `delete` | Delete the child | Delete the associated children |
| `restrict` | Reject removal | Reject parent deletion |

A required association rejects a detach policy. Reparenting is an explicit grouped move that preserves the child's ID and bypasses removal-driven deletion. A locally observed deletion or competing move rejects a stale operation and preserves its draft. Destructive child deletion checks for newer child edits; detachment preserves unrelated newer fields.

The current command API rejects incompatible overlaps, such as reparenting to a parent the same session deletes. It also rejects deletion of a child type that has its own registered parent associations, rather than attempting a recursive cascade. These are errors while constructing the draft operation; handle them before calling `apply`.

These checks concern the state presented to `apply`. They do not coordinate independently running devices. A successful session exposes `undoReceipt`, whose `undo(in:)` validates the inverse against current fields, identities, and observed deletion evidence. Restoring a deleted child requires its owner to exist or be restored in the same inverse. Removing a created parent rejects children attached after the original group. `EntityEditPersistence.undo(_:in:)` saves that inverse before publishing state. The existing snapshot-based ``UndoPlugin`` remains a separate API without these association guards.

A partial storage merge retains an explicit deletion tombstone even when the row is already absent locally. That evidence prevents guarded undo from restoring a locally deleted row after another writer also deletes it. History scans exclude the coordinator's own deletion transactions and canonical grouped deletion transactions from remote deletion evidence. It creates no pending local deletion, and a later accepted arrival clears the evidence.
