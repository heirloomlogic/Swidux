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

/// `Optional<T>` is as optional as `T?`: no default, `@Ignored` and a to-one
/// `@Relation` all accept it.
@Persisted
nonisolated struct SpelledOptionalNote: Identifiable, Equatable, Sendable {
    var id: UUID
    var link: Optional<URL>
    @Ignored var preview: Optional<String>
    @Relation(deleteRule: .nullify) var chapter: Optional<Chapter>
}

/// An entity nested in another type, as a feature namespace would hold it.
enum NestingLibrary {
    @Persisted
    nonisolated struct Volume: Identifiable, Equatable, Sendable {
        var id: UUID
        var title: String = ""
    }
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

    @Test("Optional<T> round-trips like T?")
    func optionalSpellingRoundTrips() throws {
        let note = SpelledOptionalNote(
            id: UUID(),
            link: URL(string: "https://example.com"),
            preview: nil,
            chapter: Chapter(id: UUID(), heading: "one")
        )

        #expect(try SpelledOptionalNoteModel(from: note).toDomain() == note)
    }

    @Test("An entity nested in another type conforms under its qualified name")
    func nestedEntityConforms() throws {
        let volume = NestingLibrary.Volume(id: UUID(), title: "kept")
        let model: NestingLibrary.Volume.Model = try NestingLibrary.VolumeModel(from: volume)

        #expect(try model.toDomain() == volume)
    }
}
