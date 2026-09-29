//
//  HistoryScan.swift
//  SwiduxPersistence
//
//  Resolves a window of SwiftData persistent history into the entity identities
//  it touched, so a remote-change tick can merge those rows instead of
//  re-reading every table. Everything here fails towards a full re-hydration:
//  no branch is allowed to answer "nothing changed" when it means "I don't know".
//

import Foundation
import SwiftData

/// One registered entity's contribution to a history scan.
///
/// `Sendable` because it crosses onto the ``EntityDB`` actor. It captures types,
/// never state — the closure exists only because reading a tombstone needs the
/// model bound concretely, which `PersistedEntity` can do and this file cannot.
struct EntityHistoryReader: Sendable {
    /// `Schema.entityName(for:)` for this entity's model, matched against
    /// `PersistentIdentifier.entityName` to attribute a change without
    /// materializing anything.
    let entityName: String

    /// The model type, used to fetch changed rows by persistent identifier.
    /// Metatypes of `PersistentModel` are `SendableMetatype`, so this crosses
    /// isolation without ceremony.
    let modelType: any PersistableModel.Type

    /// Reads a deletion's identity out of its tombstone, or `nil` if it cannot.
    ///
    /// `nil` never means "not this entity" — the scan decides that from
    /// `entityName` before asking. It means the tombstone did not yield exactly
    /// one identity, which is what a row deleted before
    /// `@Attribute(.preserveValueOnDeletion)` shipped looks like, and the tick
    /// must escalate rather than guess.
    let tombstoneID: @Sendable (HistoryChange) -> UUID?
}

/// One window of persistent history, resolved into the identities it touched.
///
/// The identities are keyed by entity rather than left flat because the scan
/// knows the attribution for free — every change arrives with a
/// `PersistentIdentifier.entityName` — and throwing it away would have the merge
/// offer every ID to every registered entity, so an app with E entities pays E
/// fetches per tick to answer one of them. ``AttributedIDs`` owns that keying,
/// and the absent-not-present-and-empty invariant that makes it trustworthy.
struct HistoryScan: Sendable {
    /// What the window named: insertions and updates to read back, deletions
    /// read from tombstones.
    var rows = AttributedIDs()

    /// The highest token in the window, or `nil` when the window was empty.
    ///
    /// The *highest*, not the last: `HistoryDescriptor.sortBy` is macOS 26+, so
    /// below that the fetch order is unspecified and "the last one" is whatever
    /// the store felt like returning.
    var newWatermark: DefaultHistoryToken?

    /// Why this window can't be merged row by row, when it can't.
    ///
    /// Set rather than thrown, because the window was still *read*: every
    /// tombstone in it that did yield an identity is in ``rows``, and a full
    /// re-read can't recover those from an empty table — the empty-snapshot
    /// guard forbids inferring what they prove. So the fallback is handed them
    /// as declared deletions, and anchors at ``newWatermark``, the end of the
    /// window it has accounted for.
    var escalation: HistoryScanFailure?

    /// Records the first reason the window needs a full read.
    mutating func escalate(_ reason: HistoryScanFailure) {
        if escalation == nil { escalation = reason }
    }
}

/// Why a window could not be resolved into identities.
///
/// Every case escalates the tick to a full re-hydration, and none of them is a
/// data failure — they are reported through `onDiagnostic`, not `onFailure`. A
/// store that records no usable history is a capability gap, not a broken store.
enum HistoryScanFailure: Error, Sendable {
    /// There is no watermark to scan from — the first tick of a session, or the
    /// first after a container rebuild. Expected, and not a problem.
    case noWatermark

    /// The watermark is older than the oldest retained transaction, so the
    /// window between them is unknowable.
    case tokenExpired

    /// A deletion of a mirrored model whose tombstone carried no single
    /// identity. Absence is the only evidence left, and only a full read has it.
    case unidentifiedDeletion(entityName: String)

    /// An inserted or updated row that could not be resolved to an identity and
    /// was not deleted later in the same window. Dropping it would advance the
    /// watermark past a change nobody read.
    case unresolvedChanges(entityName: String)

    /// Another writer deleted a row of a model no registration mirrors but a
    /// registered one reaches through a relationship — a `@Relation` child —
    /// without changing any row that embeds it. A deleted child can't be traced
    /// to the parent that held it, so only a full read of the parents can
    /// deliver the removal.
    case embeddedChange(entityName: String)

    /// More than one store behind the container. `DefaultHistoryToken` is a
    /// per-store vector and `Comparable` orders it totally, which is not a
    /// componentwise upper bound — so `> max` can exclude a second store's later
    /// transaction permanently.
    case multipleStores

    /// The history fetch itself threw.
    case fetchFailed(String)
}

// MARK: - Reading history

extension EntityDB {
    /// Whether CloudKit mirroring is configured behind this container.
    ///
    /// Pruning consults it: a mirrored store has a second history consumer whose
    /// progress there is no API to ask about, and deleting a transaction it has
    /// not exported resets the sync state.
    var isCloudKitBacked: Bool {
        modelContainer.configurations.contains { $0.cloudKitContainerIdentifier != nil }
    }

    /// Resolves every transaction after `watermark` into the identities it
    /// touched.
    ///
    /// Pass `nil` for `watermark` only to measure a window from the beginning of
    /// retained history; the tick uses ``currentHistoryToken()`` to anchor
    /// instead, which is cheaper and doesn't materialize every change.
    ///
    /// A window that was read but holds a change this scan can't attribute to
    /// a row comes back with ``HistoryScan/escalation`` set: re-read everything,
    /// and apply the tombstones it did read.
    ///
    /// - Throws: ``HistoryScanFailure`` for anything that leaves the window
    ///   unreadable. Every case means "re-read everything", never "nothing
    ///   changed" — a scan that returns with no escalation has accounted for
    ///   every change it saw.
    func changes(
        since watermark: DefaultHistoryToken?,
        readers: [EntityHistoryReader]
    ) throws -> HistoryScan {
        // One store, or the token stops being a usable anchor — see
        // `HistoryScanFailure.multipleStores`.
        guard modelContainer.configurations.count <= 1 else {
            throw HistoryScanFailure.multipleStores
        }

        let transactions = try transactions(since: watermark)
        var scan = HistoryScan()
        guard !transactions.isEmpty else { return scan }

        let byName = Dictionary(
            readers.map { ($0.entityName, $0) }, uniquingKeysWith: { first, _ in first })
        let relations = EmbeddedRelations(
            registered: byName.mapValues(\.modelType), schema: modelContainer.schema)
        var changedPIDs: [String: [PersistentIdentifier]] = [:]
        var embeddedPIDs: [String: [PersistentIdentifier]] = [:]
        var deletedPIDs: Set<PersistentIdentifier> = []

        // One pass. The window can hold every change of a first CloudKit import,
        // and `flatMap(\.changes)` would materialize a second array as large as
        // the transactions it came from, alongside them.
        for transaction in transactions {
            // The *highest* token, not the last: `HistoryDescriptor.sortBy` is
            // macOS 26+, so below that the fetch order is unspecified.
            if scan.newWatermark.map({ transaction.token > $0 }) ?? true {
                scan.newWatermark = transaction.token
            }
            let isOwnWrite = transaction.author == transactionAuthor
            var touched: Set<String> = []
            var embeddedDeletions: Set<String> = []
            for change in transaction.changes {
                let identifier = change.changedPersistentIdentifier
                guard let reader = byName[identifier.entityName] else {
                    // A model a registered entity embeds: its rows *are* in
                    // state, inside their parents, so another writer's change
                    // to one is traced to the registered row holding it —
                    // skipping it would consume it unread, and the parent's next
                    // save would write the stale child back over it. Our own
                    // saves wrote these children *from* state, so they have
                    // nothing to teach this scan.
                    guard relations.modelTypes[identifier.entityName] != nil, !isOwnWrite else {
                        // A model no registered entity mirrors or reaches. Its
                        // rows are not in state, so nothing here has anything
                        // to say.
                        continue
                    }
                    if case .delete = change {
                        embeddedDeletions.insert(identifier.entityName)
                    } else {
                        embeddedPIDs[identifier.entityName, default: []].append(identifier)
                    }
                    continue
                }
                touched.insert(reader.entityName)
                switch change {
                case .delete:
                    deletedPIDs.insert(identifier)
                    guard !isOwnWrite else { continue }
                    guard let id = reader.tombstoneID(change) else {
                        scan.escalate(.unidentifiedDeletion(entityName: reader.entityName))
                        continue
                    }
                    scan.rows.insert(
                        deleted: [id], for: reader.entityName,
                        evidence: DeletionEvidence(
                            historyToken: transaction.token,
                            transaction: EntityEditTransaction.id(from: transaction.author)))
                case .insert, .update:
                    changedPIDs[reader.entityName, default: []].append(identifier)
                @unknown default:
                    // A change kind this build doesn't know about, against a
                    // model it does mirror. Treating it as "nothing happened"
                    // would advance the watermark past it; re-reading costs a tick.
                    scan.escalate(.unresolvedChanges(entityName: reader.entityName))
                }
            }
            // A deleted child has no row left to trace to its parent. The
            // parent's own change is what delivers it — a cascade deletes the
            // parent, and a save that drops a child rewrites the parent — so a
            // deletion that arrived with a change to a registered row embedding
            // its model is accounted for. One that arrived alone is not.
            for entityName in embeddedDeletions
            where touched.isDisjoint(with: relations.registeredAncestors[entityName] ?? []) {
                scan.escalate(.embeddedChange(entityName: entityName))
            }
        }

        // A window going to be re-read in full needs no rows resolved: the
        // full read finds them anyway, and only its tombstones are owed.
        guard scan.escalation == nil else { return scan }
        let embedding = try embeddingRows(
            of: embeddedPIDs, relations: relations, registered: Set(byName.keys))
        for (entityName, ids) in embedding {
            scan.rows.insert(changed: ids, for: entityName)
        }
        for (entityName, identifiers) in changedPIDs {
            guard let reader = byName[entityName] else { continue }
            let resolved = try identities(of: identifiers, asConcrete: reader.modelType)
            // A group whose every identifier was deleted later in this same
            // window resolves to nothing; `insert` leaves the key absent, so
            // `isEmpty` can't claim the window named rows it didn't.
            scan.rows.insert(changed: Set(resolved.values), for: entityName)
            // A row that no longer exists is explicable exactly once: it was
            // deleted later in this same window, and the tombstone already named
            // it. Anything else means the window holds a change this scan cannot
            // account for, and advancing past it would lose that change for good.
            let unexplained = identifiers.contains {
                resolved[$0] == nil && !deletedPIDs.contains($0)
            }
            if unexplained {
                scan.escalate(.unresolvedChanges(entityName: entityName))
            }
        }
        return scan
    }

    /// The newest token in the store, or `nil` when it has no history yet.
    ///
    /// This is what a whole-table read installs as its anchor. Below macOS 26 it
    /// costs a scan of retained history, because `HistoryDescriptor.sortBy` —
    /// the only way to ask for "the newest one" — is 26+. Hence the fast path.
    func currentHistoryToken() throws -> DefaultHistoryToken? {
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
                predicate: nil, sortBy: [SortDescriptor(\.token, order: .reverse)])
            descriptor.fetchLimit = 1
            return try modelContext.fetchHistory(descriptor).first?.token
        }
        return try modelContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
            .lazy.map(\.token).max()
    }

    /// Deletes transactions recorded before `cutoff`, unless CloudKit mirroring
    /// is reading the same log.
    ///
    /// The mirrored-store guard lives here rather than in the caller because it
    /// is an invariant, not a policy: mirroring decides what to export from these
    /// transactions, there is no API to ask how far it has got, and deleting one
    /// it hasn't exported resets the sync state. Any future caller gets the same
    /// protection without having to know.
    ///
    /// - Parameters:
    ///   - cutoff: Transactions recorded before this instant are deleted.
    ///   - anchor: The watermark a merge will scan from next, if there is one.
    ///     It and every later transaction are kept whatever their age: pruning
    ///     the transaction a watermark names expires it, and the tick that finds
    ///     it expired falls back to a full read — the one read that can't tell a
    ///     deleted last row from an unreadable table.
    ///   - counting: Whether to count what it deletes. Counting costs a second
    ///     full evaluation of the predicate, so it is skipped when no diagnostic
    ///     handler is listening.
    /// - Returns: How many transactions were removed, or 0 when not counting.
    /// - Throws: Whatever the underlying fetch or delete throws.
    @discardableResult
    func pruneHistory(
        before cutoff: Date, keepingFrom anchor: DefaultHistoryToken? = nil, counting: Bool = true
    ) throws -> Int {
        guard !isCloudKitBacked else { return 0 }
        let descriptor: HistoryDescriptor<DefaultHistoryTransaction>
        if let anchor {
            descriptor = HistoryDescriptor(predicate: #Predicate { $0.timestamp < cutoff && $0.token < anchor })
        } else {
            descriptor = HistoryDescriptor(predicate: #Predicate { $0.timestamp < cutoff })
        }
        let doomed = counting ? try modelContext.fetchHistory(descriptor).count : 0
        if counting, doomed == 0 { return 0 }
        try modelContext.deleteHistory(descriptor)
        return doomed
    }

    /// Every transaction after `watermark`, or all of retained history when
    /// there is no watermark yet.
    func transactions(
        since watermark: DefaultHistoryToken?
    ) throws -> [DefaultHistoryTransaction] {
        let descriptor =
            watermark.map {
                anchor in
                HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.token > anchor })
            } ?? HistoryDescriptor<DefaultHistoryTransaction>()
        do {
            return try modelContext.fetchHistory(descriptor)
        } catch SwiftDataError.historyTokenExpired {
            throw HistoryScanFailure.tokenExpired
        } catch {
            throw HistoryScanFailure.fetchFailed("\(error)")
        }
    }

    /// Maps persistent identifiers to entity identities, chunked by
    /// ``EntityDB/chunks(_:)`` like every other batched read.
    ///
    /// Identifiers whose row no longer exists are simply absent from the result;
    /// the caller decides whether that is explicable. That "absent, not fatal"
    /// behaviour is the whole reason this is a fetch rather than
    /// `ModelContext.model(for:)`, which returns a fault and raises an
    /// uncatchable ObjC exception for a row deleted since the scan.
    ///
    /// Internal rather than private so the tests can drive the real read. It is
    /// the only generic context in the package that builds a by-identifier
    /// fetch, and a test that reimplemented it would keep passing after this
    /// stopped using the generated descriptor.
    func identities<M: PersistableModel>(
        of identifiers: [PersistentIdentifier],
        asConcrete type: M.Type
    ) throws -> [PersistentIdentifier: UUID] {
        var resolved: [PersistentIdentifier: UUID] = [:]
        for chunk in Self.chunks(identifiers) {
            // Per-model descriptor, not a generic `#Predicate` — see `swiduxBatchFetchDescriptor`.
            let rows = try modelContext.fetch(M.swiduxBatchFetchDescriptor(persistentIDs: chunk))
            for row in rows { resolved[row.persistentModelID] = row.id }
        }
        return resolved
    }
}

extension HistoryScanFailure: CustomStringConvertible {
    var description: String {
        switch self {
        case .noWatermark:
            "no watermark yet"
        case .tokenExpired:
            "the stored watermark is older than the oldest retained transaction"
        case .unidentifiedDeletion(let entityName):
            "a deleted \(entityName) row left no identity in its tombstone"
        case .unresolvedChanges(let entityName):
            "a changed \(entityName) row could not be resolved to an identity"
        case .embeddedChange(let entityName):
            "a \(entityName) row changed that is only readable through its parent"
        case .multipleStores:
            "history tokens are not a total order across more than one store"
        case .fetchFailed(let message):
            "the history fetch failed: \(message)"
        }
    }
}
