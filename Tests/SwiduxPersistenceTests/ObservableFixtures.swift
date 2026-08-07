//
//  ObservableFixtures.swift
//  SwiduxPersistenceTests
//
//  Shared fixtures for the persistence tests: a hand-written `SwiduxObservable`
//  conformance for `NotesState`, kept hand-rolled on purpose so the tests exercise
//  the path an app takes when it writes the conformance itself. (`@Swidux` is
//  available here — this target depends on `Swidux`; `SliceWiringTests.swift` uses
//  it.) Plus the store, container, and seeding helpers every suite in this target
//  needs.
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
    container: ModelContainer? = nil,
    debounce: Duration = .milliseconds(10),
    retry: RetryPolicy = .default,
    mergePolicy: MergePolicy = .preferRemote,
    entityPolicy: MergePolicy? = nil,
    collapse: (@Sendable ([Note]) -> [Note])? = nil,
    onFailure: PersistenceFailureHandler? = nil,
    onDiagnostic: PersistenceDiagnosticHandler? = nil
) throws -> PersistenceCoordinator<NotesState, NotesAction> {
    PersistenceCoordinator<NotesState, NotesAction>(
        entities: [.entity(\.notes, policy: entityPolicy, collapse: collapse)],
        container: try container ?? makeNotesContainer(),
        debounce: debounce,
        retry: retry,
        mergePolicy: mergePolicy,
        onFailure: onFailure,
        onDiagnostic: onDiagnostic
    )
}

/// A live store wired to `coordinator`'s persistence plugin, and to `undo` when
/// one is supplied.
@MainActor
func makeNotesStore(
    _ coordinator: PersistenceCoordinator<NotesState, NotesAction>,
    initialState: NotesState = NotesState(),
    undo: UndoPlugin<NotesState, NotesAction>? = nil
) -> Store<NotesState, NotesAction> {
    let plugins = PluginHost<NotesState, NotesAction>()
    if let undo { plugins.register(undo) }
    plugins.register(coordinator.corePlugin)
    return Store(
        initialState: initialState,
        reducer: notesReducer,
        plugins: plugins,
        undoPlugin: undo,
        persistencePlugin: coordinator.corePlugin
    )
}

/// Thread-safe box for collecting values from `@Sendable` closures.
///
/// A sibling of the one in `SwiduxTests`; test targets can't import each
/// other's helpers, and a shared test-support target would be more machinery
/// than two small boxes are worth.
final class SendableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    var value: T {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    init(_ value: T) { storage = value }

    /// Mutates in place under the lock — for read-modify-write, where a
    /// get/set pair would race.
    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&storage) }
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses.
///
/// Retry backoff and debounce timers complete on their own schedule, so tests
/// wait for an observable state rather than sleeping a fixed span — a sleep
/// that is generous on an idle machine is not generous on a loaded CI runner.
@MainActor
func poll(until condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
    var waited = Duration.zero
    while !condition(), waited < timeout {
        try await Task.sleep(for: .milliseconds(5))
        waited += .milliseconds(5)
    }
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

/// Inserts `count` rows that all share `id`.
@MainActor
func seedDuplicates(
    _ container: ModelContainer,
    id: UUID,
    title: String = "dup",
    count: Int
) throws {
    try seedNotes(container, Array(repeating: Note(id: id, title: title, pinned: false), count: count))
}

/// Every raw row on disk, duplicates included — `fetchAll` collapses, so it
/// can't be used to verify what is actually stored.
@MainActor
func rawNoteRows(_ container: ModelContainer) throws -> [NoteModel] {
    try ModelContext(container).fetch(FetchDescriptor<NoteModel>())
}
