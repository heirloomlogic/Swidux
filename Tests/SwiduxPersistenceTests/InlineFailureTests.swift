import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

@Persisted
struct InlineRecord: Equatable, Sendable {
    var id: UUID
    var title: String
    @Inline var numbers: [Double] = []
}

@Swidux
nonisolated struct InlineRecordsState: Equatable, Sendable {
    var records: EntityStore<InlineRecord> = EntityStore()
}

enum InlineRecordsAction: Equatable, Sendable { case put(InlineRecord) }

@MainActor
func inlineRecordsReducer(
    state: inout InlineRecordsState, action: InlineRecordsAction
) -> Effect<InlineRecordsAction>? {
    switch action {
    case .put(let record): state.records[record.id] = record
    }
    return nil
}

@Suite("Inline persistence failures")
struct InlineFailureTests {
    @Test("Unencodable inserts fail without creating empty blobs")
    func invalidInsert() async throws {
        let db = EntityDB(
            modelContainer: try ContainerFactory.makeInMemoryContainer(
                models: [InlineRecordModel.self]))
        let invalid = InlineRecord(id: UUID(), title: "invalid", numbers: [.infinity])
        let failure = await #expect(throws: UnencodableRows.self) {
            try await db.upsert(invalid, as: InlineRecordModel.self)
        }
        #expect(failure?.failedIDs == [invalid.id])
        #expect(failure?.underlying is EncodingError, "the conversion error is what an app can act on")
        #expect(try await db.fetchAll(of: InlineRecord.self).isEmpty)
    }

    @Test("An encoding failure fails only its own row, and saves the rest of the batch")
    func invalidUpdateFailsAlone() async throws {
        let db = EntityDB(
            modelContainer: try ContainerFactory.makeInMemoryContainer(
                models: [InlineRecordModel.self]))
        let original = InlineRecord(id: UUID(), title: "original", numbers: [1, 2])
        try await db.upsert(original, as: InlineRecordModel.self)
        let other = InlineRecord(id: UUID(), title: "saved anyway", numbers: [3])
        let invalid = InlineRecord(id: original.id, title: "changed", numbers: [.nan])
        let failure = await #expect(throws: UnencodableRows.self) {
            try await db.apply(writes: [other, invalid], deletions: [], as: InlineRecordModel.self)
        }
        #expect(failure?.failedIDs == [original.id], "the error names the culprit, and only it")
        let stored = try await db.fetchAll(of: InlineRecord.self)
        #expect(
            Set(stored.map(\.id)) == [original.id, other.id],
            "a value that can never encode must not hold the rest of its batch back")
        #expect(
            stored.first { $0.id == original.id } == original,
            "the failed row is left exactly as it was — not half-updated")
    }

    @Test("One unencodable value does not block later writes of the same type")
    @MainActor
    func poisonedRowDoesNotBlockItsType() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [InlineRecordModel.self])
        let (failures, onFailure) = failureLog()
        let (log, onDiagnostic) = diagnosticLog()
        let coordinator = PersistenceCoordinator<InlineRecordsState, InlineRecordsAction>(
            entities: [.entity(\.records)], container: container, debounce: .seconds(30),
            retry: .never, historyRetention: nil, onFailure: onFailure, onDiagnostic: onDiagnostic)
        let plugins = PluginHost<InlineRecordsState, InlineRecordsAction>()
        plugins.register(coordinator.corePlugin)
        let store = Store(
            initialState: InlineRecordsState(), reducer: inlineRecordsReducer, plugins: plugins,
            persistencePlugin: coordinator.corePlugin)

        let a = InlineRecord(id: UUID(), title: "a", numbers: [1])
        let b = InlineRecord(id: UUID(), title: "b", numbers: [2])
        store.send(.put(a))
        store.send(.put(b))
        await coordinator.corePlugin.flush()

        // A chart series that divided by zero. JSON has no spelling for it.
        var poisoned = a
        poisoned.numbers = [.infinity]
        store.send(.put(poisoned))
        await coordinator.corePlugin.flush()

        // Unrelated edits keep arriving, and every flush of this type carries
        // the poisoned row with it.
        for n in 1...3 {
            var edited = b
            edited.title = "b edit \(n)"
            store.send(.put(edited))
            await coordinator.corePlugin.flush()
        }

        let disk = try await coordinator.fetchAll(of: InlineRecord.self, flushPending: false)
        #expect(disk.first { $0.id == b.id }?.title == "b edit 3", "one bad value held every write of its type hostage")
        #expect(disk.first { $0.id == a.id } == a, "the poisoned value is not on disk, and nothing replaced it")

        let saves = failures.failures(.save)
        #expect(!saves.isEmpty)
        #expect(saves.allSatisfy { $0.failedIDs == [a.id] }, "every failure names the culprit and nothing else")
        #expect(
            log.value.last { $0.kind == .writesUnpersisted }?.unpersistedIDs == [a.id],
            "only the culprit is off disk")
        #expect(store.records[a.id] == poisoned, "memory keeps the value, still owned, for the app to fix")
    }
}
