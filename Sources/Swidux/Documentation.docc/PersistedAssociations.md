# Persisting canonical associations

Declare parent and child identities separately, then save an editing session through one local transaction.

`@BelongsTo` stores an optional owner UUID. `@HasMany` stores a UUID array used only for order. Both generate optional SwiftData relationships with reciprocal inverses. Domain converters read scalar values and never recursively convert the other endpoint.

```swift
import Foundation
import Swidux
import SwiduxPersistence

@Persisted
struct Book: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    @HasMany(Chapter.self, inverse: "bookID") var chapterIDs: [UUID] = []
}

@Persisted
struct Chapter: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    @BelongsTo(Book.self, inverse: "chapterIDs") var bookID: UUID?
}

struct Library: Sendable {
    var books = EntityStore<Book>()
    var chapters = EntityStore<Chapter>()
}
```

Both declarations must name each other's domain property. They can be in separate source files. Two named associations between the same entity types use separate owner fields and order arrays. `ContainerFactory` validates reciprocal declarations before constructing the schema. Duplicate domain IDs are rejected by grouped writes when they make an association graph ambiguous; the writer does not pick or delete a duplicate row.

The child owner UUID determines membership. The generated reference is rebuilt from that UUID during local writes. A missing parent leaves the UUID intact and the reference unresolved; inserting the parent later resolves it. An external reference-only edit does not change domain ownership. A grouped deletion of a parent still named by a surviving child is rejected. Express detach or delete through the session's explicit ownership policies.

## Local editing and ordering

```swift
@MainActor
func makeAssociation() throws -> EntityAssociation<Library, Book, Chapter> {
    try EntityAssociation(
        name: "chapters", parents: \Library.books, children: \Library.chapters,
        owner: \Chapter.bookID, order: \Book.chapterIDs,
        requiredness: .optional, removal: .delete, parentDeletion: .delete)
}
```

Register this descriptor in the session's `EntityAssociationCatalog`. `children(of:in:)` resolves current canonical children in the parent's ID order. Duplicate order entries are ignored when reading; listed IDs whose child has not arrived or belongs elsewhere contribute no child. Current members absent from the list follow in UUID string order. Order metadata never attaches, detaches, or deletes a child. Missing IDs remain stored so a later arrival can occupy its recorded position.

`session.reorder(_:for:through:)` records one field edit and rejects duplicate IDs. Reorder-only saves persist. Concurrent changes to the same order array conflict as one field; the session does not merge two reorder operations. Child creation or reparenting does not rewrite the order arrays. Add an explicit reorder to the same session when a specific insertion position matters.

## Durable groups

`EntityEditPersistence` selects grouped writes for its container. Create it before starting writes and use it for every editing session in that container. It stages a session against current canonical state, checks the changed entities against disk, performs one SwiftData save, and then publishes the staged state. There is no actor suspension between validation and publication. A field conflict, disk conflict, conversion failure, or save failure leaves canonical state and the session draft intact.

```swift
@MainActor
func save(_ session: EntityEditSession<Library>, state: inout Library,
          persistence: EntityEditPersistence<Library>) throws {
    let result = try persistence.commit(session, to: &state)
    guard result.wasApplied else {
        // Present result.conflicts; session.draft still contains the edits.
        return
    }
}

@MainActor
func makeWriter(_ container: ModelContainer) throws -> EntityEditPersistence<Library> {
    try EntityEditPersistence(container: container, entities: [
        .entity(\Library.books), .entity(\Library.chapters)
    ])
}
```

Local field edits merge against canonical state using the contract in <doc:EntityEditingGuide>. The durable check is more conservative: any difference between a changed entity or required parent endpoint and its canonical pre-save value rejects the group with `EntityPersistenceConflict`, retaining typed original/current/proposed entities. Refresh canonical state before retrying. Register every store the session can change, including children detached by parent deletion, or require as a parent endpoint; an omitted store rejects the commit before writing. A successful commit acknowledges the saved IDs in each store's pending changes, leaving unrelated pending changes intact.

Each deleted ID records the successful transaction's UUID in that canonical store. A merge compares retained tombstones by history token and suppresses remote-deletion evidence only for a matching acknowledgement. State copies keep independent acknowledgement values, so another state sharing the container or grouped writer still receives deletions it did not commit. A repeated local deletion replaces the token; restoration, an accepted arrival, or an observed foreign deletion clears it. The metadata therefore holds at most one token per currently absent locally deleted ID and survives a pending-change reset.

Ordinary `EntityDB` upserts, deletes, collapses, and debounced coordinator flushes throw `groupedWritesRequired` after this writer selects grouped mode. This also fences writes queued before the mode was selected. Do not install a debounced writer for this container; coordinator reads and hydration remain available. A grouped save invalidates an in-flight coordinator merge read into a live `Store`, which retries before publishing fetched values. Package group writers share a lock for the same container. Raw `ModelContext` writes, separate containers for the same file, other processes, and CloudKit imports are outside that lock.

For imports or initial rows, build an `EntityPersistenceGroup` with `change(from:to:)` and call `EntityDB.apply(_:)`. An absent original means insert; an absent proposed value means delete. Every expected value is checked before any mutation, and every conversion must succeed before the single save. This lower-level API enforces stored identity and association references; it does not infer an application's removal or deletion policies.

## Guarded undo

After a successful apply, `session.undoReceipt` holds a single-use `EntityEditUndo`. It checks the whole inverse before changing state. Field undo touches only fields changed by the session. Undoing creation requires the complete created entity and its registered dependent membership to remain unchanged. Undoing deletion requires the ID to remain absent with no observed remote deletion, and any owner must exist or be restored by the same inverse. Reparent undo checks the owner field and requires the original parent to exist. Newer unrelated fields and entities remain intact.

Use `receipt.undo(in:)` for in-memory state, or `persistence.undo(_:in:)` to save the inverse before publishing it. An undo conflict retains the receipt for inspection or retry. The snapshot-based `UndoPlugin` does not provide these guards and is a separate API.

## Storage and synchronization boundary

The generated reference column is `_swidux_<property>Reference`; an inline JSON blob is `_swidux_<property>Data`. User properties colliding with either generated name produce a diagnostic. SwiftData inverse references use nullify rules; session policies own destructive operations. The scalar UUID and UUID-array columns keep their domain property names.

These generated association schemas are currently local-only. `ContainerFactory` throws `SwiduxAssociationError.synchronizationUnavailable` when a mirrored container includes them, even though their inverses satisfy SwiftData's schema requirement. Remote deletion evidence, partial delivery, competing ownership/order changes, reconnect behavior, and account isolation still need synchronization reconciliation and signed-device acceptance under [#102](https://github.com/heirloomlogic/Swidux/issues/102) and [#109](https://github.com/heirloomlogic/Swidux/issues/109). Local tests and schema inspection do not establish those guarantees.

`@Relation` was removed in 2.0.0. Use `@Inline` for an owned value without independent identity. Use the identity-based declarations above when children are independently editable.

## Breaking schema change

Inline backing columns now use `_swidux_<property>Data` instead of `<property>Data`. Generated references use the same reserved naming scheme. This release validates fresh stores only; it supplies no migration mappings, legacy readers, or old-schema compatibility. Release notes should include this under `Breaking` as tracked in [#111](https://github.com/heirloomlogic/Swidux/issues/111). Conditional stored-property declarations still produce the existing `#if` diagnostic; that separate part of [#113](https://github.com/heirloomlogic/Swidux/issues/113) is unchanged.
