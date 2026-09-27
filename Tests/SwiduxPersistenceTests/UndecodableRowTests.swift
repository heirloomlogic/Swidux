//
//  UndecodableRowTests.swift
//  SwiduxPersistenceTests
//
//  One stored row this build cannot decode must cost that row, not its whole
//  entity. The realistic trigger is version skew rather than corruption: a newer
//  app version adds a case to an `@Inline` type, writes one row using it, and
//  every older device on the same iCloud account reads that row back.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

// MARK: - Fixtures

/// Stands in for an `@Inline` payload a newer app version wrote: it encodes
/// fine, but this build refuses to decode anything above version 1.
struct SkewedPayload: Codable, Equatable, Sendable {
    var version: Int

    init(version: Int) { self.version = version }

    private enum CodingKeys: String, CodingKey { case version }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version <= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "written by a newer app version")
        }
        self.version = version
    }
}

@Persisted
struct VersionedDoc: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    @Inline var payload: SkewedPayload = SkewedPayload(version: 1)
}

@Swidux
nonisolated struct VersionedDocsState: Equatable, Sendable {
    var docs: EntityStore<VersionedDoc> = EntityStore()
}

enum VersionedDocsAction: Equatable, Sendable { case put(VersionedDoc) }

@MainActor
func versionedDocsReducer(
    state: inout VersionedDocsState, action: VersionedDocsAction
) -> Effect<VersionedDocsAction>? {
    switch action {
    case .put(let doc): state.docs[doc.id] = doc
    }
    return nil
}

@MainActor
private func makeDocsCoordinator(
    collapse: (@Sendable ([VersionedDoc]) -> [VersionedDoc])? = nil,
    onFailure: PersistenceFailureHandler? = nil
) throws -> PersistenceCoordinator<VersionedDocsState, VersionedDocsAction> {
    PersistenceCoordinator<VersionedDocsState, VersionedDocsAction>(
        entities: [.entity(\.docs, collapse: collapse)],
        container: try ContainerFactory.makeInMemoryContainer(models: [VersionedDocModel.self]),
        debounce: .seconds(30), historyRetention: nil, onFailure: onFailure)
}

@MainActor
private func makeDocsStore(
    _ coordinator: PersistenceCoordinator<VersionedDocsState, VersionedDocsAction>
) -> Store<VersionedDocsState, VersionedDocsAction> {
    let plugins = PluginHost<VersionedDocsState, VersionedDocsAction>()
    plugins.register(coordinator.corePlugin)
    return Store(
        initialState: VersionedDocsState(), reducer: versionedDocsReducer, plugins: plugins,
        persistencePlugin: coordinator.corePlugin)
}

/// Writes the way a peer on a newer version would — behind the store's back.
@MainActor
private func peerWrite(
    _ coordinator: PersistenceCoordinator<VersionedDocsState, VersionedDocsAction>,
    _ docs: [VersionedDoc]
) async throws {
    try await coordinator.database.apply(writes: docs, deletions: [], as: VersionedDocModel.self)
}

private let good = VersionedDoc(id: UUID(), title: "fine")
private let skewed = VersionedDoc(id: UUID(), title: "from v2", payload: SkewedPayload(version: 2))

// MARK: - Tests

@Suite("Rows this build cannot decode")
@MainActor
struct UndecodableRowTests {
    @Test("one undecodable row does not hide every other row at launch")
    func launchReadsEverythingElse() async throws {
        let (failures, onFailure) = failureLog()
        let coordinator = try makeDocsCoordinator(onFailure: onFailure)
        try await peerWrite(coordinator, [good, skewed])

        var state = VersionedDocsState()
        await coordinator.hydrate(into: &state)

        #expect(state.docs[good.id] == good, "one skewed row hid every row of its entity")
        #expect(state.docs[skewed.id] == nil)
        #expect(failures.failures(.fetch).count == 1)
        #expect(failures.failures(.fetch).first?.failedIDs == [skewed.id], "the failure names the row it cost")
    }

    @Test("a registered collapse does not turn one undecodable row into a hidden entity")
    func launchWithACollapseReadsEverythingElse() async throws {
        let (failures, onFailure) = failureLog()
        let coordinator = try makeDocsCoordinator(collapse: { $0 }, onFailure: onFailure)
        try await peerWrite(coordinator, [good, skewed])

        var state = VersionedDocsState()
        await coordinator.hydrate(into: &state)

        #expect(state.docs[good.id] == good)
        #expect(failures.failures(.fetch).first?.failedIDs == [skewed.id])
        let rows = try ModelContext(coordinator.database.modelContainer).fetch(FetchDescriptor<VersionedDocModel>())
        #expect(rows.count == 2, "a resolver that cannot see every row must not delete any of them")
    }

    @Test("one undecodable row does not freeze merges for its entity")
    func mergesKeepFlowing() async throws {
        let coordinator = try makeDocsCoordinator()
        let store = makeDocsStore(coordinator)
        try await peerWrite(coordinator, [good])
        await coordinator.mergeChanges(into: store)  // anchor
        #expect(store.docs[good.id] == good)

        try await peerWrite(coordinator, [skewed])
        await coordinator.mergeChanges(into: store)
        let pinned = coordinator.handle.anchor.token

        for n in 1...3 {
            var edited = good
            edited.title = "edit \(n)"
            try await peerWrite(coordinator, [edited])
            await coordinator.mergeChanges(into: store)
        }

        #expect(coordinator.handle.anchor.token != pinned, "the watermark was pinned behind the skewed row")
        #expect(store.docs[good.id]?.title == "edit 3", "the entity stopped syncing for the session")
    }

    @Test("a held row that becomes undecodable is neither overwritten nor inferred deleted")
    func anUndecodableRowIsLocallyOwned() async throws {
        let coordinator = try makeDocsCoordinator()
        let store = makeDocsStore(coordinator)
        let other = VersionedDoc(id: UUID(), title: "other")
        try await peerWrite(coordinator, [good, other])
        await coordinator.mergeChanges(into: store)  // anchor
        #expect(store.docs[good.id] == good)

        // A newer peer rewrites a row this device already shows.
        var upgraded = good
        upgraded.payload = SkewedPayload(version: 2)
        try await peerWrite(coordinator, [upgraded])

        // Both paths: the narrow one reads it by ID, the full one infers
        // deletion from whatever the snapshot lacks.
        await coordinator.mergeChanges(into: store)
        #expect(store.docs[good.id] == good, "an unreadable row is not evidence of anything")
        await coordinator.rehydrate(into: store)
        #expect(store.docs[good.id] == good, "absence from a snapshot that could not decode it is not deletion")
        #expect(store.docs[other.id] == other)
    }

    @Test("a resolver skipped for an undecodable duplicate says why")
    func aSkippedResolverIsReported() async throws {
        let (failures, onFailure) = failureLog()
        let calls = SendableBox(0)
        let coordinator = try makeDocsCoordinator(
            collapse: { rows in
                calls.withValue { $0 += 1 }
                return rows
            },
            onFailure: onFailure)
        let id = UUID()
        // Two rows for one id, the second written by a newer version. The
        // first decodes, so a plain read collapses to it — but the resolver
        // is handed every row, and can't be handed this one.
        let context = ModelContext(coordinator.database.modelContainer)
        context.insert(try VersionedDocModel(from: VersionedDoc(id: id, title: "v1 row")))
        try context.save()
        context.insert(
            try VersionedDocModel(from: VersionedDoc(id: id, title: "v2 dup", payload: SkewedPayload(version: 2))))
        try context.save()

        var state = VersionedDocsState()
        await coordinator.hydrate(into: &state)

        #expect(state.docs[id]?.title == "v1 row", "the decodable row still loads")
        #expect(calls.value == 0, "the premise: a resolver that can't see every row does not run")
        #expect(
            failures.failures(.fetch).first?.failedIDs == [id],
            "the resolver silently never ran, and nothing said why")
    }
}
