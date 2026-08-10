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

/// The identities one window of persistent history touched.
struct HistoryScan: Sendable {
    /// Inserted or updated — read these back and reconcile them.
    var changed: Set<UUID> = []

    /// Deleted, read from tombstones. Positive evidence, unlike an absent row.
    var deleted: Set<UUID> = []

    /// The highest token in the window, or `nil` when the window was empty.
    ///
    /// The *highest*, not the last: `HistoryDescriptor.sortBy` is macOS 26+, so
    /// below that the fetch order is unspecified and "the last one" is whatever
    /// the store felt like returning.
    var newWatermark: DefaultHistoryToken?

    /// How many transactions the window held. Zero means there is nothing to do
    /// at all — not even a merge.
    var transactionCount = 0

    /// Whether the window named no rows this store mirrors.
    var isEmpty: Bool { changed.isEmpty && deleted.isEmpty }
}

/// Why a window could not be resolved into identities.
///
/// Every case escalates the tick to a full re-hydration, and none of them is a
/// data failure — they are reported through `onDiagnostic`, not `onFailure`. A
/// store that records no usable history is a capability gap, not a broken store.
enum HistoryScanFailure: Error, Sendable {
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
        scan.transactionCount = transactions.count
        guard !transactions.isEmpty else { return scan }
        scan.newWatermark = transactions.map(\.token).max()

        let byName = Dictionary(
            readers.map { ($0.entityName, $0) }, uniquingKeysWith: { first, _ in first })
        var changedPIDs: [String: [PersistentIdentifier]] = [:]
        var deletedPIDs: Set<PersistentIdentifier> = []

        for change in transactions.flatMap(\.changes) {
            let identifier = change.changedPersistentIdentifier
            // A model no registered entity mirrors. Its rows are not in state, so
            // nothing here has anything to say about them.
            guard let reader = byName[identifier.entityName] else { continue }
            switch change {
            case .delete:
                deletedPIDs.insert(identifier)
                guard let id = reader.tombstoneID(change) else {
                    throw HistoryScanFailure.unidentifiedDeletion(entityName: reader.entityName)
                }
                scan.deleted.insert(id)
            case .insert, .update:
                changedPIDs[reader.entityName, default: []].append(identifier)
            @unknown default:
                // A change kind this build doesn't know about, against a model
                // it does mirror. Treating it as "nothing happened" would advance
                // the watermark past it; re-reading the table costs a tick.
                throw HistoryScanFailure.unresolvedChanges(entityName: reader.entityName)
            }
        }

        for (entityName, identifiers) in changedPIDs {
            guard let reader = byName[entityName] else { continue }
            let unique = identifiers.reduce(into: [PersistentIdentifier]()) {
                if !$1.isContained(in: $0) { $0.append($1) }
            }
            let resolved = try identities(of: unique, as: reader.modelType)
            scan.changed.formUnion(resolved.values)
            // A row that no longer exists is explicable exactly once: it was
            // deleted later in this same window, and the tombstone already named
            // it. Anything else means the window holds a change this scan cannot
            // account for, and advancing past it would lose that change for good.
            let unexplained = unique.contains { resolved[$0] == nil && !deletedPIDs.contains($0) }
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
            .map(\.token).max()
    }

    /// Deletes transactions recorded before `cutoff`.
    ///
    /// - Returns: How many transactions were removed.
    @discardableResult
    func pruneHistory(before cutoff: Date) throws -> Int {
        let descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: #Predicate { $0.timestamp < cutoff })
        let doomed = try modelContext.fetchHistory(descriptor).count
        guard doomed > 0 else { return 0 }
        try modelContext.deleteHistory(descriptor)
        return doomed
    }

    /// Every transaction after `watermark`, or all of retained history when
    /// there is no watermark yet.
    private func transactions(
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

    /// Maps persistent identifiers to entity identities, in chunks.
    ///
    /// Opens the model existential so the `#Predicate` is built against a
    /// concrete type. Identifiers whose row no longer exists are simply absent
    /// from the result — the caller decides whether that is explicable. That
    /// "absent, not fatal" behaviour is the whole reason this is a fetch rather
    /// than `ModelContext.model(for:)`, which returns a fault and raises an
    /// uncatchable ObjC exception for a row deleted since the scan.
    private func identities(
        of identifiers: [PersistentIdentifier],
        as type: any PersistableModel.Type
    ) throws -> [PersistentIdentifier: UUID] {
        try identities(of: identifiers, asConcrete: type)
    }

    private func identities<M: PersistableModel>(
        of identifiers: [PersistentIdentifier],
        asConcrete type: M.Type
    ) throws -> [PersistentIdentifier: UUID] {
        var resolved: [PersistentIdentifier: UUID] = [:]
        for start in stride(from: 0, to: identifiers.count, by: Self.batchFetchChunkSize) {
            let chunk = Array(
                identifiers[start..<min(start + Self.batchFetchChunkSize, identifiers.count)])
            let rows = try modelContext.fetch(
                FetchDescriptor<M>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))
            for row in rows { resolved[row.persistentModelID] = row.id }
        }
        return resolved
    }
}

extension PersistentIdentifier {
    /// Whether `identifiers` already holds this one.
    ///
    /// `PersistentIdentifier` is `Hashable`, but deduplicating through a `Set`
    /// would make the chunk boundaries — and so the fetch order — depend on
    /// per-process seeding, which is the trap `EntityDB.idChunks` documents.
    fileprivate func isContained(in identifiers: [PersistentIdentifier]) -> Bool {
        identifiers.contains(self)
    }
}

extension HistoryScanFailure: CustomStringConvertible {
    var description: String {
        switch self {
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

extension Duration {
    /// This duration in seconds, for the `Date` arithmetic a retention window
    /// needs. Sub-second precision is irrelevant at that scale and is dropped.
    var seconds: TimeInterval { TimeInterval(components.seconds) }
}
