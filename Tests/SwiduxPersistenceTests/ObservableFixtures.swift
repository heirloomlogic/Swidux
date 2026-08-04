//
//  ObservableFixtures.swift
//  SwiduxPersistenceTests
//
//  A hand-written `SwiduxObservable` conformance for `NotesState`, so the
//  persistence tests can drive a real `Store` (the `@Swidux` macro isn't
//  available here — SwiduxPersistence's test target doesn't depend on it).
//

import Foundation
import Swidux

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
