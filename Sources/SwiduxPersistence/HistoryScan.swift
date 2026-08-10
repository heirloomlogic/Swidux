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

/// The identities one window of persistent history touched, keyed by the entity
/// that owns them.
///
/// Keyed rather than flat because the scan knows the attribution for free —
/// every change arrives with a `PersistentIdentifier.entityName` — and throwing
/// it away would have the merge offer every ID to every registered entity, so an
/// app with E entities pays E fetches per tick to answer one of them.
///
/// An entity with nothing in the window is **absent**, never present-and-empty.
/// The two would be indistinguishable to ``isEmpty``, and a window that resolved
/// to no identities at all must not read as one that named some.
struct HistoryScan: Sendable {
    /// Inserted or updated — read these back and reconcile them.
    var changed: [String: Set<UUID>] = [:]

    /// Deleted, read from tombstones. Positive evidence, unlike an absent row.
    var deleted: [String: Set<UUID>] = [:]

    /// The highest token in the window, or `nil` when the window was empty.
    ///
    /// The *highest*, not the last: `HistoryDescriptor.sortBy` is macOS 26+, so
    /// below that the fetch order is unspecified and "the last one" is whatever
    /// the store felt like returning.
    var newWatermark: DefaultHistoryToken?

    /// Whether the window named no rows this store mirrors.
    var isEmpty: Bool { changed.isEmpty && deleted.isEmpty }

    /// How many identities the window named, across every entity.
    var count: Int {
        changed.values.reduce(0) { $0 + $1.count } + deleted.values.reduce(0) { $0 + $1.count }
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
    /// - Throws: ``HistoryScanFailure`` for anything that leaves the window
    ///   unknowable. Every case means "re-read everything", never "nothing
    ///   changed" — a scan that returns normally has accounted for every change
    ///   it saw.
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
        var changedPIDs: [String: [PersistentIdentifier]] = [:]
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
            for change in transaction.changes {
                let identifier = change.changedPersistentIdentifier
                // A model no registered entity mirrors. Its rows are not in
                // state, so nothing here has anything to say about them.
                guard let reader = byName[identifier.entityName] else { continue }
                switch change {
                case .delete:
                    deletedPIDs.insert(identifier)
                    guard let id = reader.tombstoneID(change) else {
                        throw HistoryScanFailure.unidentifiedDeletion(entityName: reader.entityName)
                    }
                    scan.deleted[reader.entityName, default: []].insert(id)
                case .insert, .update:
                    changedPIDs[reader.entityName, default: []].append(identifier)
                @unknown default:
                    // A change kind this build doesn't know about, against a
                    // model it does mirror. Treating it as "nothing happened"
                    // would advance the watermark past it; re-reading costs a tick.
                    throw HistoryScanFailure.unresolvedChanges(entityName: reader.entityName)
                }
            }
        }

        for (entityName, identifiers) in changedPIDs {
            guard let reader = byName[entityName] else { continue }
            let resolved = try identities(of: identifiers, asConcrete: reader.modelType)
            // Absent, not present-and-empty: a group whose every identifier was
            // deleted later in this same window resolves to nothing, and leaving
            // the key behind would make `isEmpty` claim the window named rows.
            if !resolved.isEmpty {
                scan.changed[entityName, default: []].formUnion(resolved.values)
            }
            // A row that no longer exists is explicable exactly once: it was
            // deleted later in this same window, and the tombstone already named
            // it. Anything else means the window holds a change this scan cannot
            // account for, and advancing past it would lose that change for good.
            let unexplained = identifiers.contains {
                resolved[$0] == nil && !deletedPIDs.contains($0)
            }
            if unexplained {
                throw HistoryScanFailure.unresolvedChanges(entityName: entityName)
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
    ///   - counting: Whether to count what it deletes. Counting costs a second
    ///     full evaluation of the predicate, so it is skipped when no diagnostic
    ///     handler is listening.
    /// - Returns: How many transactions were removed, or 0 when not counting.
    /// - Throws: Whatever the underlying fetch or delete throws.
    @discardableResult
    func pruneHistory(before cutoff: Date, counting: Bool = true) throws -> Int {
        guard !isCloudKitBacked else { return 0 }
        let descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: #Predicate { $0.timestamp < cutoff })
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
        case .multipleStores:
            "history tokens are not a total order across more than one store"
        case .fetchFailed(let message):
            "the history fetch failed: \(message)"
        }
    }
}
