//
//  TwoEntityFixtures.swift
//  SwiduxPersistenceTests
//
//  A second registered entity, which is the only way to observe what a merge
//  does *per entity*. Every other fixture in this target registers one
//  `EntityStore`, so "did this tick read the entity nothing changed in?" has no
//  answer there — there is no such entity.
//
//  `Tag` deliberately carries the same `id: UUID` shape as `Note`: identities
//  don't collide across types in practice, but a test can make them collide on
//  purpose, and that is what turns "was this entity read?" into an assertion.
//

import Foundation
import Swidux
import SwiftData

@testable import SwiduxPersistence

// MARK: - The second entity

@Persisted
struct Tag: Identifiable, Equatable, Sendable {
    var id: UUID
    var label: String
}

/// Root state with two registered entities.
///
/// Generated rather than hand-written, unlike `NotesState`: that one is
/// hand-rolled on purpose, to exercise the path an app takes when it writes the
/// conformance itself, and one fixture doing that is enough.
@Swidux
nonisolated struct TaggedState: Equatable, Sendable {
    var notes: EntityStore<Note> = EntityStore()
    var tags: EntityStore<Tag> = EntityStore()
}

// MARK: - Actions

enum TaggedAction: Equatable, Sendable {
    case addNote(Note)
    case addTag(Tag)
}

@MainActor
func taggedReducer(state: inout TaggedState, action: TaggedAction) -> Effect<TaggedAction>? {
    switch action {
    case .addNote(let note):
        state.notes[note.id] = note
    case .addTag(let tag):
        state.tags[tag.id] = tag
    }
    return nil
}

// MARK: - Harness

@MainActor
func makeTaggedContainer() throws -> ModelContainer {
    try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self, TagModel.self])
}

/// Registers `notes` first and `tags` second, so a test that asserts on `tags`
/// is asserting about an entity the phase reaches *after* the one that changed.
@MainActor
func makeTaggedCoordinator(
    container: ModelContainer? = nil,
    debounce: Duration = .seconds(30),
    onDiagnostic: PersistenceDiagnosticHandler? = nil
) throws -> PersistenceCoordinator<TaggedState, TaggedAction> {
    PersistenceCoordinator<TaggedState, TaggedAction>(
        entities: [.entity(\.notes), .entity(\.tags)],
        container: try container ?? makeTaggedContainer(),
        debounce: debounce,
        onDiagnostic: onDiagnostic
    )
}

@MainActor
func makeTaggedStore(
    _ coordinator: PersistenceCoordinator<TaggedState, TaggedAction>
) -> Store<TaggedState, TaggedAction> {
    let plugins = PluginHost<TaggedState, TaggedAction>()
    plugins.register(coordinator.corePlugin)
    return Store(
        initialState: TaggedState(),
        reducer: taggedReducer,
        plugins: plugins,
        persistencePlugin: coordinator.corePlugin
    )
}

/// Writes the way another device's changes arrive — through the database,
/// behind the store's back.
@MainActor
func remoteWriteNotes(
    _ coordinator: PersistenceCoordinator<TaggedState, TaggedAction>,
    writes: [Note] = [],
    deletions: Set<UUID> = []
) async throws {
    try await coordinator.database.apply(writes: writes, deletions: deletions, as: NoteModel.self)
}

@MainActor
func remoteWriteTags(
    _ coordinator: PersistenceCoordinator<TaggedState, TaggedAction>,
    writes: [Tag] = [],
    deletions: Set<UUID> = []
) async throws {
    try await coordinator.database.apply(writes: writes, deletions: deletions, as: TagModel.self)
}

/// Inserts rows through a second `ModelContext`, bypassing `EntityDB` entirely —
/// the only way to manufacture the duplicate-ID rows the collapse probe needs.
@MainActor
func seedTags(_ container: ModelContainer, _ tags: [Tag]) throws {
    let context = ModelContext(container)
    for tag in tags { context.insert(try TagModel(from: tag)) }
    try context.save()
}
