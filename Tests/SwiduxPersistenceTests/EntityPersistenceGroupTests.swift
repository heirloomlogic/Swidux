import Foundation
import Swidux
import SwiftData
import Testing

@testable import SwiduxPersistence

@MainActor
@Suite("Atomic entity persistence groups")
struct EntityPersistenceGroupTests {
    @Test("heterogeneous writes commit together and stale guards reject the entire group")
    func groupedWrites() async throws {
        let container = try makeTaggedContainer()
        let db = EntityDB(modelContainer: container)
        let note = Note(id: UUID(), title: "Original", pinned: false)
        let tag = Tag(id: UUID(), label: "Original")
        var initial = EntityPersistenceGroup()
        try initial.change(from: Optional<Note>.none, to: note)
        try initial.change(from: Optional<Tag>.none, to: tag)
        try await db.apply(initial)
        var edited = note
        edited.title = "Edited"
        var editedTag = tag
        editedTag.label = "Edited"
        var group = EntityPersistenceGroup()
        try group.change(from: note, to: edited)
        try group.change(from: tag, to: editedTag)
        var remote = tag
        remote.label = "Other writer"
        try await db.upsert(remote, as: TagModel.self)
        await #expect(throws: EntityPersistenceConflict.self) { try await db.apply(group) }
        #expect(try await db.fetchAll(NoteModel.self) == [note])
        #expect(try await db.fetchAll(TagModel.self) == [remote])
    }
}

@MainActor
@Suite("Durable edit sessions")
struct DurableEditSessionTests {
    @Test("durable commit consumes a session only after save and fences ordinary writers")
    func durableCommit() async throws {
        let container = try makeTaggedContainer()
        let db = EntityDB(modelContainer: container)
        let note = Note(id: UUID(), title: "Original", pinned: false)
        try await db.upsert(note, as: NoteModel.self)
        var state = TaggedState(notes: EntityStore([note]))
        let session = EntityEditSession(state: state)
        try session.edit(
            Note.self, id: note.id, in: \TaggedState.notes, field: \Note.title, named: "title", to: "Draft")
        let persistence = try EntityEditPersistence<TaggedState>(
            container: container, entities: [.entity(\.notes), .entity(\.tags)])
        #expect(try persistence.commit(session, to: &state).wasApplied)
        #expect(state.notes[note.id]?.title == "Draft")
        #expect(state.notes.changes.isEmpty)
        #expect(try await db.fetchAll(NoteModel.self).first?.title == "Draft")
        await #expect(throws: EntityPersistenceGroupError.groupedWritesRequired) {
            try await db.upsert(note, as: NoteModel.self)
        }
        #expect(try await db.fetchAll(NoteModel.self).first?.title == "Draft")
    }

    @Test("a disk conflict preserves every draft and leaves canonical state unchanged")
    func preservesDraft() async throws {
        let container = try makeTaggedContainer()
        let note = Note(id: UUID(), title: "Original", pinned: false)
        let db = EntityDB(modelContainer: container)
        try await db.upsert(note, as: NoteModel.self)
        var state = TaggedState(notes: EntityStore([note]))
        let session = EntityEditSession(state: state)
        try session.edit(
            Note.self, id: note.id, in: \TaggedState.notes, field: \Note.title, named: "title", to: "Draft")
        var changed = note
        changed.title = "Other context"
        try await db.upsert(changed, as: NoteModel.self)
        let persistence = try EntityEditPersistence<TaggedState>(container: container, entities: [.entity(\.notes)])
        #expect(throws: EntityPersistenceConflict.self) { try persistence.commit(session, to: &state) }
        #expect(state.notes[note.id] == note)
        #expect(session.draft(Note.self, id: note.id, in: \TaggedState.notes)?.title == "Draft")
    }
}

@MainActor
@Suite("Grouped write failure boundaries")
struct GroupedWriteFailureTests {
    @Test("a conversion failure rolls back an earlier update and preserves all rows")
    func conversionRollback() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self, InlineRecordModel.self])
        let db = EntityDB(modelContainer: container)
        let note = Note(id: UUID(), title: "Original", pinned: false)
        try await db.upsert(note, as: NoteModel.self)
        var changed = note
        changed.title = "Changed"
        let poison = InlineRecord(id: UUID(), title: "Bad", numbers: [.infinity])
        var group = EntityPersistenceGroup()
        try group.change(from: note, to: changed)
        try group.change(from: Optional<InlineRecord>.none, to: poison)
        await #expect(throws: EncodingError.self) { try await db.apply(group) }
        #expect(try await db.fetchAll(NoteModel.self) == [note])
        #expect(try await db.fetchAll(InlineRecordModel.self).isEmpty)
    }

    @Test("duplicate identities reject a group without selecting a row")
    func duplicateIdentity() async throws {
        let container = try makeTaggedContainer()
        let note = Note(id: UUID(), title: "Duplicate", pinned: false)
        let context = ModelContext(container)
        context.insert(try NoteModel(from: note))
        context.insert(try NoteModel(from: note))
        try context.save()
        var group = EntityPersistenceGroup()
        var changed = note
        changed.title = "Overwrite"
        try group.change(from: note, to: changed)
        let db = EntityDB(modelContainer: container)
        await #expect(throws: EntityPersistenceGroupError.self) { try await db.apply(group) }
        #expect(try ModelContext(container).fetch(FetchDescriptor<NoteModel>()).allSatisfy { $0.title == "Duplicate" })
    }

    @Test("a debounced write queued before grouped mode cannot overwrite a committed session")
    func queuedWriterIsFenced() async throws {
        let container = try makeTaggedContainer()
        let note = Note(id: UUID(), title: "Original", pinned: false)
        let coordinator = try makeTaggedCoordinator(container: container)
        let store = makeTaggedStore(coordinator)
        try await coordinator.database.upsert(note, as: NoteModel.self)
        store.send(.addNote(note))
        var canonical = TaggedState(notes: EntityStore([note]))
        let session = EntityEditSession(state: canonical)
        try session.edit(
            Note.self, id: note.id, in: \TaggedState.notes, field: \Note.title, named: "title", to: "Committed")
        let writer = try EntityEditPersistence<TaggedState>(container: container, entities: [.entity(\.notes)])
        #expect(try writer.commit(session, to: &canonical).wasApplied)
        await coordinator.corePlugin.flush()
        #expect(try await coordinator.fetchAll(of: Note.self, flushPending: false).first?.title == "Committed")
    }
    @Test("a save failure leaves canonical state and the complete session draft intact")
    func saveFailure() throws {
        let note = Note(id: UUID(), title: "Original", pinned: false)
        let container = try makeUnwritableNotesContainer(seeding: [note])
        var state = TaggedState(notes: EntityStore([note]))
        let session = EntityEditSession(state: state)
        try session.edit(
            Note.self, id: note.id, in: \TaggedState.notes, field: \Note.title, named: "title", to: "Draft")
        let writer = try EntityEditPersistence<TaggedState>(container: container, entities: [.entity(\.notes)])
        #expect(throws: (any Error).self) { try writer.commit(session, to: &state) }
        #expect(state.notes[note.id] == note)
        #expect(state.notes.changes.isEmpty)
        #expect(session.draft(Note.self, id: note.id, in: \TaggedState.notes)?.title == "Draft")
        #expect(session.preview(applyingTo: state).result.wasApplied)
        #expect(try ModelContext(container).fetch(FetchDescriptor<NoteModel>()).first?.title == "Original")
    }
}
