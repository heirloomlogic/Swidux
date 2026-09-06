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

@Suite("Inline persistence failures")
struct InlineFailureTests {
    @Test("Unencodable inserts fail without creating empty blobs")
    func invalidInsert() async throws {
        let db = EntityDB(
            modelContainer: try ContainerFactory.makeInMemoryContainer(
                models: [InlineRecordModel.self]))
        let invalid = InlineRecord(id: UUID(), title: "invalid", numbers: [.infinity])
        await #expect(throws: EncodingError.self) {
            try await db.upsert(invalid, as: InlineRecordModel.self)
        }
        #expect(try await db.fetchAll(of: InlineRecord.self).isEmpty)
    }

    @Test("An encoding failure rolls back the entire batch, including earlier rows")
    func invalidUpdateRollsBackBatch() async throws {
        let db = EntityDB(
            modelContainer: try ContainerFactory.makeInMemoryContainer(
                models: [InlineRecordModel.self]))
        let original = InlineRecord(id: UUID(), title: "original", numbers: [1, 2])
        try await db.upsert(original, as: InlineRecordModel.self)
        let other = InlineRecord(id: UUID(), title: "also rolled back", numbers: [3])
        let invalid = InlineRecord(id: original.id, title: "changed", numbers: [.nan])
        await #expect(throws: EncodingError.self) {
            try await db.apply(writes: [other, invalid], deletions: [], as: InlineRecordModel.self)
        }
        #expect(try await db.fetchAll(of: InlineRecord.self) == [original])
    }
}
