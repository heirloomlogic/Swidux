//
//  ObservableFixtures.swift
//  SwiduxPersistenceTests
//
//  Shared fixtures for the persistence tests: a hand-written `SwiduxObservable`
//  conformance for `NotesState` (the `@Swidux` macro isn't available here —
//  SwiduxPersistence's test target doesn't depend on it), plus the store,
//  container, and seeding helpers every suite in this target needs.
//

import Foundation
import Swidux
import SwiftData

@testable import SwiduxPersistence

// MARK: - Observer

@Observable
@MainActor
final class NotesStateObserver {
    var notes: EntityStore<Note>
    var ui: NotesUI

    init(notes: EntityStore<Note> = EntityStore(), ui: NotesUI = NotesUI()) {
        self.notes = notes
        self.ui = ui
    }
}

extension NotesState: SwiduxObservable {
    typealias Observer = NotesStateObserver

    @MainActor
    init(observer: NotesStateObserver) {
        self.notes = observer.notes
        self.ui = observer.ui
    }

    @MainActor
    static func makeObserver(from state: NotesState) -> NotesStateObserver {
        NotesStateObserver(notes: state.notes, ui: state.ui)
    }

    @MainActor
    static func apply(_ snapshot: NotesState, to observer: NotesStateObserver) {
        observer.notes = snapshot.notes
        observer.ui = snapshot.ui
    }

    @MainActor
    static func applyRestore(from snapshot: NotesState, to current: inout NotesState) {
        current.notes.restore(from: snapshot.notes)
        current.ui = snapshot.ui
    }
}

// MARK: - Actions

enum NotesAction: Equatable, Sendable {
    case add(Note)
    case remove(UUID)
    case setSearchText(String)
}

@MainActor
func notesReducer(state: inout NotesState, action: NotesAction) -> Effect<NotesAction>? {
    switch action {
    case .add(let note):
        state.notes[note.id] = note
    case .remove(let id):
        state.notes[id] = nil
    case .setSearchText(let text):
        state.ui.searchText = text
    }
    return nil
}

// MARK: - Harness

@MainActor
func makeNotesContainer() throws -> ModelContainer {
    try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
}

@MainActor
func makeNotesCoordinator(
    debounce: Duration = .milliseconds(10),
    mergePolicy: MergePolicy = .preferRemote,
    entityPolicy: MergePolicy? = nil,
    collapse: (@Sendable ([Note]) -> [Note])? = nil,
    onFailure: PersistenceFailureHandler? = nil
) throws -> PersistenceCoordinator<NotesState, NotesAction> {
    PersistenceCoordinator<NotesState, NotesAction>(
        entities: [.entity(\.notes, policy: entityPolicy, collapse: collapse)],
        container: try makeNotesContainer(),
        debounce: debounce,
        mergePolicy: mergePolicy,
        onFailure: onFailure
    )
}

/// A live store wired to `coordinator`'s persistence plugin.
@MainActor
func makeNotesStore(
    _ coordinator: PersistenceCoordinator<NotesState, NotesAction>,
    initialState: NotesState = NotesState()
) -> Store<NotesState, NotesAction> {
    let plugins = PluginHost<NotesState, NotesAction>()
    plugins.register(coordinator.corePlugin)
    return Store(
        initialState: initialState,
        reducer: notesReducer,
        plugins: plugins,
        persistencePlugin: coordinator.corePlugin
    )
}

/// Inserts rows through a second `ModelContext`, bypassing `EntityDB` entirely.
///
/// This is the only way to manufacture the duplicate-ID rows the API under test
/// is designed to survive — every `EntityDB` write path refuses to create them.
@MainActor
func seedNotes(_ container: ModelContainer, _ notes: [Note]) throws {
    let context = ModelContext(container)
    for note in notes { context.insert(NoteModel(from: note)) }
    try context.save()
}

/// Every raw row on disk, duplicates included — `fetchAll` collapses, so it
/// can't be used to verify what is actually stored.
@MainActor
func rawNoteRows(_ container: ModelContainer) throws -> [NoteModel] {
    try ModelContext(container).fetch(FetchDescriptor<NoteModel>())
}
