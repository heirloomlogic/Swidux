//
//  PersistedMacroCompiledTests.swift
//  SwiduxPersistenceTests
//
//  `@Persisted` applied in a compiled target. `PersistedMacroTests` asserts the
//  text the macro emits, and `assertMacroExpansion` never type-checks it — so a
//  property the generator silently skipped, or an expansion that only compiles
//  with an import the user never wrote, passes there and fails only here.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

// MARK: - Fixtures

/// A stored property with an observer is still stored, and must round-trip.
@Persisted
nonisolated struct ObservedNote: Identifiable, Equatable, Sendable {
    var id: UUID
    var rating: Int = 0 {
        didSet { rating = min(max(rating, 0), 5) }
    }
    var title: String = "" {
        willSet {}
    }
}

/// Type-level members are not columns.
@Persisted
nonisolated struct VersionedNote: Identifiable, Equatable, Sendable {
    nonisolated(unsafe) static var schemaVersion: Int = 1
    static let kind: String = "note"

    var id: UUID
    var body: String = ""
}

// MARK: - Tests

@Suite("@Persisted compiled expansion")
struct PersistedMacroCompiledTests {
    @Test("A property with willSet/didSet round-trips through the model")
    func observedPropertyRoundTrips() throws {
        var note = ObservedNote(id: UUID())
        note.rating = 4
        note.title = "kept"

        let back = try ObservedNoteModel(from: note).toDomain()

        #expect(back == note)
    }

    @Test("Static members are not mirrored onto the model")
    func staticMembersAreSkipped() throws {
        let note = VersionedNote(id: UUID(), body: "kept")

        #expect(try VersionedNoteModel(from: note).toDomain() == note)
    }
}
