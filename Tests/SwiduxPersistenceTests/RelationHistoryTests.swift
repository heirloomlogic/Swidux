//
//  RelationHistoryTests.swift
//  SwiduxPersistenceTests
//
//  `@Relation` children are rows of their own model, usually unregistered: they
//  live inside the parent's domain value. A peer that edits only a child records
//  a history change against the child's model and nothing against the parent,
//  so a scan that skips models no registration mirrors never reads it — and the
//  parent's next save writes the stale child back over the peer's edit.
//

import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

// MARK: - Fixtures

@Swidux
nonisolated struct ShelfState: Equatable, Sendable {
    var books: EntityStore<Book> = EntityStore()
}

enum ShelfAction: Equatable, Sendable {
    case put(Book)
    case setTitle(UUID, String)
}

@MainActor
func shelfReducer(state: inout ShelfState, action: ShelfAction) -> Effect<ShelfAction>? {
    switch action {
    case .put(let book): state.books[book.id] = book
    case .setTitle(let id, let title): state.books.modify(id) { $0.title = title }
    }
    return nil
}

@MainActor
private func makeShelf(
    onDiagnostic: PersistenceDiagnosticHandler? = nil
) throws -> (
    coordinator: PersistenceCoordinator<ShelfState, ShelfAction>, store: Store<ShelfState, ShelfAction>,
    container: ModelContainer
) {
    let container = try ContainerFactory.makeInMemoryContainer(
        models: [BookModel.self, ChapterModel.self, ColophonModel.self])
    // Registered the documented way: the parent only.
    let coordinator = PersistenceCoordinator<ShelfState, ShelfAction>(
        entities: [.entity(\.books)], container: container, debounce: .seconds(30),
        historyRetention: nil, onDiagnostic: onDiagnostic)
    let plugins = PluginHost<ShelfState, ShelfAction>()
    plugins.register(coordinator.corePlugin)
    let store = Store(
        initialState: ShelfState(), reducer: shelfReducer, plugins: plugins,
        persistencePlugin: coordinator.corePlugin)
    return (coordinator, store, container)
}

/// Two levels of nesting: a registered library whose books embed chapters.
@Persisted
struct Library: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String = ""
    @Relation(deleteRule: .cascade) var books: [Book] = []
}

@Swidux
nonisolated struct LibraryState: Equatable, Sendable {
    var libraries: EntityStore<Library> = EntityStore()
}

enum LibraryAction: Equatable, Sendable { case put(Library) }

@MainActor
func libraryReducer(state: inout LibraryState, action: LibraryAction) -> Effect<LibraryAction>? {
    switch action {
    case .put(let library): state.libraries[library.id] = library
    }
    return nil
}

// MARK: - Tests

@Suite("@Relation children in persistent history")
@MainActor
struct RelationHistoryTests {
    @Test("a peer's edit to a child surfaces, and the parent's next save keeps it")
    func aChildOnlyEditSurfaces() async throws {
        let (coordinator, store, container) = try makeShelf()
        let book = Book(id: UUID(), title: "t", chapters: [Chapter(id: UUID(), heading: "one")])
        try await coordinator.database.apply(writes: [book], deletions: [], as: BookModel.self)
        await coordinator.mergeChanges(into: store)  // anchor
        #expect(store.books[book.id]?.chapters.first?.heading == "one")

        // Another writer — an app extension, or app code with its own context —
        // renames the chapter and touches nothing else.
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<ChapterModel>()).first)
        row.heading = "renamed"
        try context.save()

        await coordinator.mergeChanges(into: store)
        #expect(
            store.books[book.id]?.chapters.first?.heading == "renamed",
            "a tick that skips the child's model consumes the change without reading it")

        // An unrelated local edit to the parent rewrites its whole subtree from
        // memory, so memory must have caught up first.
        store.send(.setTitle(book.id, "retitled"))
        await coordinator.corePlugin.flush()
        let onDisk = try ModelContext(container).fetch(FetchDescriptor<ChapterModel>())
        #expect(onDisk.map(\.heading) == ["renamed"], "the peer's edit was overwritten on disk")
    }

    @Test("this coordinator's own saves of a subtree do not cost a full read")
    func ownSubtreeWritesStayNarrow() async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let (coordinator, store, _) = try makeShelf(onDiagnostic: onDiagnostic)
        var book = Book(id: UUID(), title: "t", chapters: [Chapter(id: UUID(), heading: "one")])
        store.send(.put(book))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)  // anchor
        log.clear()

        // The user edits a chapter and adds another. Memory is where those
        // values came from, so the tick that reads them back has nothing to
        // learn from the children and no reason to re-read every table.
        book.chapters[0].heading = "edited here"
        book.chapters.append(Chapter(id: UUID(), heading: "two"))
        store.send(.put(book))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)

        #expect(!log.contains(.historyUnavailable), "\(log.fallbackReasons)")
        #expect(store.books[book.id] == book)
    }

    @Test("a peer deleting the last parent with children is applied, and not resurrected")
    func thePeerDeletedLastParentIsApplied() async throws {
        let (coordinator, store, container) = try makeShelf()
        let book = Book(id: UUID(), title: "only", chapters: [Chapter(id: UUID(), heading: "one")])
        store.send(.put(book))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)  // anchor

        // The peer deletes the book, and its chapters go with it.
        let peer = ModelContext(container)
        for chapter in try peer.fetch(FetchDescriptor<ChapterModel>()) { peer.delete(chapter) }
        for row in try peer.fetch(FetchDescriptor<BookModel>()) { peer.delete(row) }
        try peer.save()

        await coordinator.mergeChanges(into: store)
        await coordinator.mergeChanges(into: store)
        #expect(store.books[book.id] == nil, "the peer's deletion of the last book never lands")

        // What that costs: the user edits the book they can still see.
        if store.books[book.id] != nil { store.send(.setTitle(book.id, "edited")) }
        await coordinator.corePlugin.flush()
        #expect(try ModelContext(container).fetch(FetchDescriptor<BookModel>()).isEmpty, "resurrected on disk")
    }

    @Test("a tick that has to re-read everything still applies the tombstones its window held")
    func aFallbackAppliesTheWindowsTombstones() async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let (coordinator, store, container) = try makeShelf(onDiagnostic: onDiagnostic)
        let book = Book(id: UUID(), title: "only", chapters: [])
        store.send(.put(book))
        await coordinator.corePlugin.flush()
        // A chapter no book holds — left behind by an older build, say.
        let seed = ModelContext(container)
        seed.insert(try ChapterModel(from: Chapter(id: UUID(), heading: "stray")))
        try seed.save()
        await coordinator.mergeChanges(into: store)  // anchor
        log.clear()

        // One window: a change nothing can attribute to a parent, which forces
        // the full read, and the deletion of the last book.
        let peer = ModelContext(container)
        for stray in try peer.fetch(FetchDescriptor<ChapterModel>()) { peer.delete(stray) }
        try peer.save()
        for row in try peer.fetch(FetchDescriptor<BookModel>()) { peer.delete(row) }
        try peer.save()

        await coordinator.mergeChanges(into: store)
        #expect(log.contains(.historyUnavailable), "the premise: this tick re-read everything")
        await coordinator.mergeChanges(into: store)

        #expect(
            store.books[book.id] == nil,
            "the full read finds an empty table, and anchoring past the window threw the tombstone away")
    }

    // MARK: - Resolving a child to its parent

    @Test("another writer's edit to a child is merged without re-reading every table")
    func aChildEditStaysNarrow() async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let (coordinator, store, container) = try makeShelf(onDiagnostic: onDiagnostic)
        let book = Book(id: UUID(), title: "t", chapters: [Chapter(id: UUID(), heading: "one")])
        let other = Book(id: UUID(), title: "other", chapters: [Chapter(id: UUID(), heading: "x")])
        store.send(.put(book))
        store.send(.put(other))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)  // anchor
        log.clear()

        let peer = ModelContext(container)
        let row = try #require(try peer.fetch(FetchDescriptor<ChapterModel>()).first { $0.heading == "one" })
        row.heading = "renamed"
        try peer.save()
        await coordinator.mergeChanges(into: store)

        #expect(store.books[book.id]?.chapters.map(\.heading) == ["renamed"])
        #expect(!log.contains(.historyUnavailable), "\(log.fallbackReasons)")
        #expect(log.merges.map(\.merged) == [1], "only the book that holds the chapter is read")
    }

    @Test("a peer creating a parent with children stays on the narrow path")
    func aPeerCreatedParentStaysNarrow() async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let (coordinator, store, _) = try makeShelf(onDiagnostic: onDiagnostic)
        store.send(.put(Book(id: UUID(), title: "existing", chapters: [])))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)  // anchor
        log.clear()

        // A second EntityDB stands in for another process running Swidux.
        let peer = EntityDB(modelContainer: coordinator.database.modelContainer)
        let book = Book(id: UUID(), title: "new", chapters: [Chapter(id: UUID(), heading: "c")])
        try await peer.upsert(book, as: BookModel.self)
        await coordinator.mergeChanges(into: store)

        #expect(store.books[book.id] == book)
        #expect(!log.contains(.historyUnavailable), "\(log.fallbackReasons)")
    }

    @Test("a peer deleting a parent with children stays on the narrow path")
    func aPeerDeletedParentStaysNarrow() async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let (coordinator, store, _) = try makeShelf(onDiagnostic: onDiagnostic)
        let doomed = Book(id: UUID(), title: "doomed", chapters: [Chapter(id: UUID(), heading: "one")])
        let kept = Book(id: UUID(), title: "kept", chapters: [])
        store.send(.put(doomed))
        store.send(.put(kept))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)  // anchor
        log.clear()

        let peer = EntityDB(modelContainer: coordinator.database.modelContainer)
        try await peer.delete(id: doomed.id, as: BookModel.self)
        await coordinator.mergeChanges(into: store)

        #expect(store.books[doomed.id] == nil)
        #expect(store.books[kept.id] == kept)
        #expect(!log.contains(.historyUnavailable), "\(log.fallbackReasons)")
    }

    @Test("a peer removing a child through its parent's save lands")
    func aPeerRemovedChildLands() async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let (coordinator, store, _) = try makeShelf(onDiagnostic: onDiagnostic)
        var book = Book(
            id: UUID(), title: "t",
            chapters: [Chapter(id: UUID(), heading: "keep"), Chapter(id: UUID(), heading: "cut")])
        store.send(.put(book))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)  // anchor

        log.clear()

        book.chapters.removeAll { $0.heading == "cut" }
        let peer = EntityDB(modelContainer: coordinator.database.modelContainer)
        try await peer.upsert(book, as: BookModel.self)
        await coordinator.mergeChanges(into: store)

        #expect(store.books[book.id]?.chapters.map(\.heading) == ["keep"])
        // The parent's save records the parent too, so the child's tombstone
        // arrives accounted for and the narrow read of the book delivers it.
        #expect(!log.contains(.historyUnavailable), "\(log.fallbackReasons)")
    }

    @Test("a grandchild edit is traced through its parent to the registered row")
    func aGrandchildEditStaysNarrow() async throws {
        let (log, onDiagnostic) = diagnosticLog()
        let container = try ContainerFactory.makeInMemoryContainer(
            models: [LibraryModel.self, BookModel.self, ChapterModel.self, ColophonModel.self])
        let coordinator = PersistenceCoordinator<LibraryState, LibraryAction>(
            entities: [.entity(\.libraries)], container: container, debounce: .seconds(30),
            historyRetention: nil, onDiagnostic: onDiagnostic)
        let plugins = PluginHost<LibraryState, LibraryAction>()
        plugins.register(coordinator.corePlugin)
        let store = Store(
            initialState: LibraryState(), reducer: libraryReducer, plugins: plugins,
            persistencePlugin: coordinator.corePlugin)
        let library = Library(
            id: UUID(), name: "l",
            books: [Book(id: UUID(), title: "b", chapters: [Chapter(id: UUID(), heading: "one")])])
        store.send(.put(library))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)  // anchor
        log.clear()

        let peer = ModelContext(container)
        let row = try #require(try peer.fetch(FetchDescriptor<ChapterModel>()).first)
        row.heading = "renamed"
        try peer.save()
        await coordinator.mergeChanges(into: store)

        #expect(store.libraries[library.id]?.books.first?.chapters.first?.heading == "renamed")
        #expect(!log.contains(.historyUnavailable), "\(log.fallbackReasons)")
    }

    @Test("a child another writer deletes directly still leaves its parent")
    func aDirectlyDeletedChildLands() async throws {
        let (coordinator, store, container) = try makeShelf()
        let book = Book(
            id: UUID(), title: "t",
            chapters: [Chapter(id: UUID(), heading: "keep"), Chapter(id: UUID(), heading: "cut")])
        store.send(.put(book))
        await coordinator.corePlugin.flush()
        await coordinator.mergeChanges(into: store)  // anchor

        // No parent save: nothing in the window says which book held the row.
        let peer = ModelContext(container)
        for row in try peer.fetch(FetchDescriptor<ChapterModel>()) where row.heading == "cut" { peer.delete(row) }
        try peer.save()
        await coordinator.mergeChanges(into: store)

        #expect(store.books[book.id]?.chapters.map(\.heading) == ["keep"])
    }
}
