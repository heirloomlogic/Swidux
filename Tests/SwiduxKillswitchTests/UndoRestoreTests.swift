//
//  UndoRestoreTests.swift
//  SwiduxKillswitchTests
//
//  Undo must never roll the killswitch back. The verdict reflects the server,
//  not anything the user did; restoring it from a snapshot taken before an
//  unrelated edit would lift a block until the next fetch.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxKillswitch

@Swidux
nonisolated struct KillswitchUndoRoot: Equatable, Sendable {
    @Slice var killswitch: KillswitchState = .init()
    var document: Int = 0
}

enum KillswitchUndoAction: Sendable {
    case killswitch(KillswitchAction)
    case edit
}

@Suite("Killswitch under undo")
@MainActor
struct KillswitchUndoRestoreTests {
    @Test("Undo does not lift a block")
    func undoKeepsBlock() {
        let isUndoable: @Sendable (KillswitchUndoAction) -> Bool = { if case .edit = $0 { true } else { false } }
        let undo = UndoPlugin<KillswitchUndoRoot, KillswitchUndoAction>(isUndoable: isUndoable)
        let plugins = PluginHost<KillswitchUndoRoot, KillswitchUndoAction>()
        plugins.register(undo)
        plugins.register(
            KillswitchPlugin<KillswitchUndoRoot, KillswitchUndoAction>(
                state: \.killswitch,
                action: KillswitchUndoAction.killswitch,
                extractAction: { if case .killswitch(let a) = $0 { a } else { nil } },
                service: .mock(),
                appVersion: { "1.0.0" },
                openURL: { _ in }
            ))
        let store = Store(
            initialState: KillswitchUndoRoot(),
            reducer: { state, action in
                if case .edit = action { state.document += 1 }
                return nil
            },
            plugins: plugins,
            undoPlugin: undo
        )
        defer { store.cancelEffects() }

        store.send(.edit)
        store.send(
            .killswitch(
                .verdictReceived(.blocked(title: "Update", message: nil, updateURL: nil), fromNetwork: true)))

        store.undo()

        #expect(store.document == 0, "the app's own edit is still undone")
        #expect(store.killswitch.verdict.isBlocked, "undo lifted the block")
    }
}
