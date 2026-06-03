//
//  PersistenceIntegrationTests.swift
//  SwiduxPersistenceTests
//
//  Covers the synthesized write-through path (EntityStore mutation → plugin
//  drain/flush → EntityDB) and the SyncStatus computed properties.
//

import Foundation
import Swidux
import SwiduxPersistence
import SwiftData
import Testing

@Suite("Persistence write-through")
struct PersistenceWriteThroughTests {
    @MainActor
    @Test("EntityStore mutations flush through the plugin into the database")
    func writeThrough() async throws {
        let container = try ContainerFactory.makeInMemoryContainer(models: [NoteModel.self])
        let coordinator = PersistenceCoordinator<NotesState, Never>(
            entities: [.entity(\.notes)],
            container: container,
            debounce: .milliseconds(10)
        )
        let id = UUID()
        var state = NotesState()

        // Insert: mutate the store, then drain + flush via the real plugin pipeline.
        state.notes[id] = Note(id: id, title: "written", pinned: false)
        coordinator.corePlugin.drainAndScheduleFlush(&state)
        await coordinator.corePlugin.flush()

        var all = try await coordinator.database.fetchAll(NoteModel.self)
        #expect(all.count == 1)
        #expect(all.first?.title == "written")

        // Delete: the same pipeline removes the row.
        state.notes[id] = nil
        coordinator.corePlugin.drainAndScheduleFlush(&state)
        await coordinator.corePlugin.flush()

        all = try await coordinator.database.fetchAll(NoteModel.self)
        #expect(all.isEmpty)
    }
}

@Suite("SyncStatus properties")
struct SyncStatusPropertyTests {
    @Test("isDegraded is false only for healthy states")
    func isDegraded() {
        #expect(SyncStatus.syncing.isDegraded == false)
        #expect(SyncStatus.localOnlyByChoice.isDegraded == false)
        #expect(SyncStatus.unavailableNotSignedIn.isDegraded)
        #expect(SyncStatus.unavailableRestricted.isDegraded)
        #expect(SyncStatus.misconfiguredNoEntitlement.isDegraded)
    }

    @Test("isUserActionable is true only for not-signed-in")
    func isUserActionable() {
        #expect(SyncStatus.unavailableNotSignedIn.isUserActionable)
        #expect(SyncStatus.syncing.isUserActionable == false)
        #expect(SyncStatus.localOnlyByChoice.isUserActionable == false)
        #expect(SyncStatus.unavailableRestricted.isUserActionable == false)
        #expect(SyncStatus.misconfiguredNoEntitlement.isUserActionable == false)
    }
}
