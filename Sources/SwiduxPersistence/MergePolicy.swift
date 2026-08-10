//
//  MergePolicy.swift
//  SwiduxPersistence
//
//  How a re-hydration resolves a storage snapshot against live in-memory state.
//

import Foundation

/// How ``PersistenceCoordinator/rehydrate(into:policy:)`` resolves a storage
/// snapshot against live in-memory state.
///
/// Every policy preserves IDs that carry unflushed local intent — that
/// guarantee is not configurable, and it is what makes remote-wins safe. The
/// policy only decides what happens to everything else.
///
/// Modelled as a struct rather than an enum so capabilities can be added
/// without breaking exhaustive matches in app code.
public struct MergePolicy: Sendable, Equatable {
    /// Whether a storage value replaces the in-memory value for an ID with no
    /// pending local write.
    public var remoteWinsOnConflict: Bool

    /// Whether an ID held in memory but absent from the snapshot — and with no
    /// pending local write — is removed as a deletion made elsewhere.
    public var removesMissingEntities: Bool

    /// Creates a policy from its two capabilities.
    public init(remoteWinsOnConflict: Bool, removesMissingEntities: Bool) {
        self.remoteWinsOnConflict = remoteWinsOnConflict
        self.removesMissingEntities = removesMissingEntities
    }

    /// Remote edits and deletions surface mid-session; a pending local write
    /// still wins. The default.
    public static let preferRemote = MergePolicy(
        remoteWinsOnConflict: true, removesMissingEntities: true)

    /// Remote edits surface, but absence from the snapshot never removes a live
    /// entity.
    ///
    /// Use where the snapshot may be incomplete rather than authoritative — in
    /// particular right after a container rebuild, where the rows simply came
    /// from a different store.
    public static let preferRemoteAdditive = MergePolicy(
        remoteWinsOnConflict: true, removesMissingEntities: false)

    /// Additive-only: the in-memory value wins for every ID already held, and
    /// nothing is ever removed.
    ///
    /// Use for stores backing live editors, where a remote edit landing under
    /// the user's cursor is worse than a stale row.
    public static let preferInMemory = MergePolicy(
        remoteWinsOnConflict: false, removesMissingEntities: false)

    /// The stricter of two policies: a capability is granted only when both
    /// grant it.
    ///
    /// Overrides compose by narrowing, never widening — a per-entity policy or
    /// a per-call override can take authority away from storage but never hand
    /// it more than the coordinator was configured to.
    public func restricted(by other: MergePolicy) -> MergePolicy {
        MergePolicy(
            remoteWinsOnConflict: remoteWinsOnConflict && other.remoteWinsOnConflict,
            removesMissingEntities: removesMissingEntities && other.removesMissingEntities
        )
    }
}

/// Everything the synchronous half of a merge needs beyond the fetched rows.
struct MergeContext {
    /// The policy in force for this entity, after all narrowing.
    let policy: MergePolicy

    /// IDs storage has no authority over: a drained-but-unflushed write, a
    /// write whose save failed, a pending deletion, or an entity the app
    /// declared it is editing.
    let locallyOwnedIDs: Set<UUID>

    /// IDs the caller has positive evidence were deleted elsewhere.
    ///
    /// Only a partial merge fills this in. A full-table merge infers deletion
    /// from a row's absence, which a snapshot covering *some* IDs cannot do —
    /// an ID that isn't there wasn't deleted, it wasn't asked for. Honoured only
    /// where ``MergePolicy/removesMissingEntities`` grants the authority, and
    /// never for an ID storage still holds.
    ///
    /// Not defaulted: a full merge passes an empty set because absence is its
    /// evidence, and that should be a statement rather than an omission.
    let deletedIDs: Set<UUID>

    /// The subset of ``locallyOwnedIDs`` exempt *only* because an
    /// ``EditingHolds`` hold is in force.
    ///
    /// A hold is the one exemption an app takes by hand, so it is the one that
    /// can be leaked — hence the only one worth reporting. IDs the writer
    /// already covers are excluded, because attributing those to the hold would
    /// point a leak hunt at the wrong thing.
    let heldIDs: Set<UUID>
}

/// IDs whose most recent flush attempt failed.
///
/// The value in memory is not in storage, so without a record of it a
/// remote-wins merge would be silent data loss — the next tick would overwrite
/// a never-persisted local edit with the stale stored row.
///
/// `StateWriter` now puts a failed batch back into its pending buffers, so
/// `pendingIDs` covers the same IDs for as long as the retry is outstanding.
/// This ledger is kept alongside it for two reasons: it also covers the window
/// while a batch is mid-flight, and it is the only record a hand-written
/// *non-throwing* persist closure — one that swallows its own error, so the
/// writer never learns to re-buffer — can leave behind.
///
/// > Note: The write itself is retried by ``Swidux/PersistencePlugin`` on a
/// > bounded backoff. When that budget is spent the app is told via a
/// > ``PersistenceFailure`` with `isFinal` set, and the batch stays pending for
/// > the next edit or explicit flush.
@MainActor
final class UnpersistedIDs {
    private(set) var ids: Set<UUID> = []

    /// - Returns: Whether ``ids`` actually changed. A second failure on the same
    ///   ID is not new information, and re-reporting it would make the
    ///   diagnostic channel unusable for anything that dedupes by content.
    @discardableResult
    func markFailed(_ failed: Set<UUID>) -> Bool {
        // Both operations are monotonic — union only grows, subtract only
        // shrinks — so the count is an exact change signal, and mutating in
        // place avoids the copy a compare-against-a-snapshot would force.
        let before = ids.count
        ids.formUnion(failed)
        return ids.count != before
    }

    /// - Returns: Whether ``ids`` actually changed. Draining to empty is a
    ///   change like any other; it is the edge an app needs to *clear* a "not
    ///   saved" indicator rather than guess at it.
    @discardableResult
    func markPersisted(_ saved: Set<UUID>) -> Bool {
        let before = ids.count
        ids.subtract(saved)
        return ids.count != before
    }
}
