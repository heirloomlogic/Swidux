//
//  RelationRoundTripTests.swift
//  SwiduxPersistenceTests
//
//  `@Relation` through a real `ModelContainer`, which nothing else covers:
//  `PersistedMacroTests` asserts the *text* the macro emits, and asserting text
//  cannot notice that the emitted `update(from:)` leaves a row behind every time
//  it runs. These write a parent several times and then count what is actually
//  on disk.
//
//  The counts are the whole point. A relationship's `deleteRule` fires when the
//  *parent* is deleted, never when a child is dropped from the relationship — so
//  a converter that rebuilds its children on every save orphans the previous set
//  rather than replacing it, and the store grows for the life of the app while
//  the UI shows nothing wrong.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

// MARK: - Fixtures

@Persisted
struct Chapter: Identifiable, Equatable, Sendable {
    var id: UUID
    var heading: String = ""
}

@Persisted
struct Colophon: Identifiable, Equatable, Sendable {
    var id: UUID
    var printer: String = ""
}

/// A parent owning both relationship shapes the generator supports.
///
/// No `inverse:` on either: an inverse is what makes SwiftData nil out the other
/// side, and leaving it off is the harsher case — nothing at all tidies up after
/// a detached row, so an accumulating converter accumulates visibly.
@Persisted
struct Book: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String = ""
    @Relation(deleteRule: .cascade) var chapters: [Chapter] = []
    @Relation(deleteRule: .cascade) var colophon: Colophon? = nil
}

@MainActor
private func makeBookContainer() throws -> ModelContainer {
    try ContainerFactory.makeInMemoryContainer(
        models: [BookModel.self, ChapterModel.self, ColophonModel.self])
}

/// Every raw row on disk for a related model, detached ones included.
///
/// Read through a second `ModelContext` rather than off the parent's
/// relationship: the relationship only names the rows the parent still points
/// at, which is exactly the set an orphan has fallen out of.
@MainActor
private func rawRows<M: PersistentModel>(_ type: M.Type, in container: ModelContainer) throws -> [M] {
    try ModelContext(container).fetch(FetchDescriptor<M>())
}

// MARK: - Tests

@Suite("@Relation round trip")
struct RelationRoundTripTests {
    @MainActor
    @Test("re-saving a parent does not accumulate child rows")
    func repeatedSaveKeepsOneRowPerChild() async throws {
        let container = try makeBookContainer()
        let db = EntityDB(modelContainer: container)
        let chapters = [
            Chapter(id: UUID(), heading: "one"),
            Chapter(id: UUID(), heading: "two"),
        ]
        var book = Book(id: UUID(), title: "v1", chapters: chapters, colophon: nil)

        for title in ["v1", "v2", "v3"] {
            book.title = title
            try await db.upsert(book, as: BookModel.self)
        }

        let rows = try rawRows(ChapterModel.self, in: container)
        #expect(rows.count == 2)
        let stored = try await db.fetchAll(BookModel.self)
        #expect(stored.count == 1)
        #expect(stored.first?.title == "v3")
        #expect(stored.first?.chapters.map(\.heading).sorted() == ["one", "two"])
    }

    @MainActor
    @Test("editing a child updates its row rather than replacing it")
    func editingAChildUpdatesInPlace() async throws {
        let container = try makeBookContainer()
        let db = EntityDB(modelContainer: container)
        let chapterID = UUID()
        var book = Book(
            id: UUID(), title: "b",
            chapters: [Chapter(id: chapterID, heading: "before")], colophon: nil)
        try await db.upsert(book, as: BookModel.self)
        let seeded = try rawRows(ChapterModel.self, in: container)
        let originalRowID = try #require(seeded.first).persistentModelID

        book.chapters = [Chapter(id: chapterID, heading: "after")]
        try await db.upsert(book, as: BookModel.self)

        let rows = try rawRows(ChapterModel.self, in: container)
        #expect(rows.count == 1)
        #expect(rows.first?.heading == "after")
        // Same row, not a replacement: a new identifier every save is what
        // churns CloudKit records and history transactions.
        #expect(rows.first?.persistentModelID == originalRowID)
    }

    @MainActor
    @Test("dropping a child from the domain array removes its row")
    func droppingAChildRemovesTheRow() async throws {
        let container = try makeBookContainer()
        let db = EntityDB(modelContainer: container)
        let kept = Chapter(id: UUID(), heading: "kept")
        var book = Book(
            id: UUID(), title: "b",
            chapters: [kept, Chapter(id: UUID(), heading: "dropped")], colophon: nil)
        try await db.upsert(book, as: BookModel.self)
        #expect(try rawRows(ChapterModel.self, in: container).count == 2)

        book.chapters = [kept]
        try await db.upsert(book, as: BookModel.self)

        let rows = try rawRows(ChapterModel.self, in: container)
        #expect(rows.count == 1)
        #expect(rows.first?.heading == "kept")
    }

    @MainActor
    @Test("clearing the array removes every child row")
    func clearingTheArrayRemovesEveryRow() async throws {
        let container = try makeBookContainer()
        let db = EntityDB(modelContainer: container)
        var book = Book(
            id: UUID(), title: "b",
            chapters: [Chapter(id: UUID(), heading: "a"), Chapter(id: UUID(), heading: "b")],
            colophon: nil)
        try await db.upsert(book, as: BookModel.self)

        book.chapters = []
        try await db.upsert(book, as: BookModel.self)

        #expect(try rawRows(ChapterModel.self, in: container).isEmpty)
        let stored = try await db.fetchAll(BookModel.self)
        #expect(stored.first?.chapters.isEmpty == true)
    }

    @MainActor
    @Test("a to-one relation is updated in place, not re-created")
    func toOneRelationUpdatesInPlace() async throws {
        let container = try makeBookContainer()
        let db = EntityDB(modelContainer: container)
        let colophonID = UUID()
        var book = Book(
            id: UUID(), title: "b", chapters: [],
            colophon: Colophon(id: colophonID, printer: "before"))
        try await db.upsert(book, as: BookModel.self)
        let seeded = try rawRows(ColophonModel.self, in: container)
        let originalRowID = try #require(seeded.first).persistentModelID

        book.colophon = Colophon(id: colophonID, printer: "after")
        try await db.upsert(book, as: BookModel.self)

        let rows = try rawRows(ColophonModel.self, in: container)
        #expect(rows.count == 1)
        #expect(rows.first?.printer == "after")
        #expect(rows.first?.persistentModelID == originalRowID)
        let stored = try await db.fetchAll(BookModel.self)
        #expect(stored.first?.colophon?.printer == "after")
    }

    @MainActor
    @Test("clearing a to-one relation removes its row")
    func clearingToOneRemovesTheRow() async throws {
        let container = try makeBookContainer()
        let db = EntityDB(modelContainer: container)
        var book = Book(
            id: UUID(), title: "b", chapters: [],
            colophon: Colophon(id: UUID(), printer: "p"))
        try await db.upsert(book, as: BookModel.self)
        #expect(try rawRows(ColophonModel.self, in: container).count == 1)

        book.colophon = nil
        try await db.upsert(book, as: BookModel.self)

        #expect(try rawRows(ColophonModel.self, in: container).isEmpty)
        let stored = try await db.fetchAll(BookModel.self)
        #expect(stored.first?.colophon == nil)
    }

    @MainActor
    @Test("replacing a to-one relation's identity removes the old row")
    func replacingToOneIdentityRemovesTheOldRow() async throws {
        let container = try makeBookContainer()
        let db = EntityDB(modelContainer: container)
        var book = Book(
            id: UUID(), title: "b", chapters: [],
            colophon: Colophon(id: UUID(), printer: "old"))
        try await db.upsert(book, as: BookModel.self)

        book.colophon = Colophon(id: UUID(), printer: "new")
        try await db.upsert(book, as: BookModel.self)

        let rows = try rawRows(ColophonModel.self, in: container)
        #expect(rows.count == 1)
        #expect(rows.first?.printer == "new")
    }
}
