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

        // A peer renames the chapter. CloudKit imports the child record alone.
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
}
