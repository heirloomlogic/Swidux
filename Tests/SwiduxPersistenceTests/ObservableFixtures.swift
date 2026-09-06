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
    historyRetention: Duration? = .seconds(7 * 24 * 60 * 60),
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
        historyRetention: historyRetention,
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

/// Collects diagnostics off the `@Sendable` handler.
///
/// The box-plus-appending-closure pair is spelled inline in half a dozen suites;
/// this is that, named once.
@MainActor
func diagnosticLog() -> (SendableBox<[PersistenceDiagnostic]>, PersistenceDiagnosticHandler) {
    let box = SendableBox<[PersistenceDiagnostic]>([])
    return (box, { diagnostic in box.withValue { $0.append(diagnostic) } })
}

/// Collects failures off the `@Sendable` handler — the other observer channel's
/// half of ``diagnosticLog()``, named here for the same reason.
@MainActor
func failureLog() -> (SendableBox<[PersistenceFailure]>, PersistenceFailureHandler) {
    let box = SendableBox<[PersistenceFailure]>([])
    return (box, { failure in box.withValue { $0.append(failure) } })
}

extension SendableBox where T == [PersistenceFailure] {
    /// The failures reported for one kind of operation.
    ///
    /// Both channels matter and they fail differently: a read reports `.fetch`
    /// and is never retried, a write reports `.save` several times over.
    /// Filtering at the assertion keeps a suite about one of them from passing
    /// on evidence of the other.
    func failures(_ operation: PersistenceFailure.Operation) -> [PersistenceFailure] {
        value.filter { $0.operation == operation }
    }
}

extension SendableBox where T == [PersistenceDiagnostic] {
    /// Whether a diagnostic of `kind` was reported — for `entityType`, when one
    /// is named.
    ///
    /// Naming the entity is what lets a multi-entity suite ask "was this entity
    /// read at all?", since a read that touches duplicate rows collapses them
    /// and says so.
    func contains(_ kind: PersistenceDiagnostic.Kind, entityType: String? = nil) -> Bool {
        value.contains { $0.kind == kind && (entityType == nil || $0.entityType == entityType) }
    }

    /// The prose reasons of every fallback reported.
    var fallbackReasons: [String] {
        value.filter { $0.kind == .historyUnavailable }.compactMap(\.fallbackReason)
    }

    /// Every narrowed tick reported, as the pair that tells one apart from
    /// another: how much was merged, and how much of that was already owed.
    ///
    /// Asking for both at once is the point — either number alone is what the
    /// conflation looked like.
    var merges: [(merged: Int, carried: Int)] {
        value.filter { $0.kind == .remoteChangesMerged }
            .map { (merged: $0.mergedCount ?? 0, carried: $0.carriedOverCount ?? 0) }
    }

    /// Forgets everything reported so far, so a later assertion speaks only for
    /// the step it follows.
    func clear() { value = [] }
}

/// Writes the way another device's changes arrive — through the database,
/// behind the store's back.
@MainActor
func remoteWrite(
    _ coordinator: PersistenceCoordinator<NotesState, NotesAction>,
    writes: [Note] = [],
    deletions: Set<UUID> = []
) async throws {
    try await coordinator.database.apply(writes: writes, deletions: deletions, as: NoteModel.self)
}

/// Inserts rows through a second `ModelContext`, bypassing `EntityDB` entirely.
///
/// This is the only way to manufacture the duplicate-ID rows the API under test
/// is designed to survive — every `EntityDB` write path refuses to create them.
///
/// - Returns: The seeded rows' persistent identifiers, in the order given —
///   what a caller needs to stand in for the ones persistent history hands back.
@MainActor
@discardableResult
func seedNotes(_ container: ModelContainer, _ notes: [Note]) throws -> [PersistentIdentifier] {
    let context = ModelContext(container)
    let rows = try notes.map { try NoteModel(from: $0) }
    for row in rows { context.insert(row) }
    try context.save()
    return rows.map(\.persistentModelID)
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
