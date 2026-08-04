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
    /// write whose save failed, or a pending deletion.
    let locallyOwnedIDs: Set<UUID>
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

    func markFailed(_ failed: Set<UUID>) {
        ids.formUnion(failed)
    }

    func markPersisted(_ saved: Set<UUID>) {
        ids.subtract(saved)
    }
}
