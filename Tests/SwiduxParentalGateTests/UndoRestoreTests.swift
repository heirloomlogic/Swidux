//
//  UndoRestoreTests.swift
//  SwiduxParentalGateTests
//
//  Undo must never roll the gate back. An undo snapshot is the whole root
//  state, taken before some unrelated edit; restoring the gate's slice from it
//  would erase a cooldown the child earned and hand back a pass the parent's
//  re-lock had revoked — one Cmd-Z or shake defeating the gate.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxParentalGate

// The documented root shape: the gate mounted as a slice beside app state.
@Swidux
nonisolated struct GateUndoRoot: Equatable, Sendable {
    @Slice var parentalGate: ParentalGateState = .init()
    var strokes: Int = 0
}

enum GateUndoAction: Sendable {
    case parental(ParentalGateAction)
    case draw
    case didEnterBackground
}

@Suite("ParentalGate under undo")
@MainActor
struct ParentalGateUndoRestoreTests {
    /// The documented wiring: undo registered first, only the app's own edit undoable.
    private typealias GateStore = Store<GateUndoRoot, GateUndoAction>

    private func makeStore(isUndoable: @escaping @Sendable (GateUndoAction) -> Bool) -> GateStore {
        let now = Date()
        let gate = ParentalGatePlugin<GateUndoRoot, GateUndoAction>(
            state: \.parentalGate,
            action: GateUndoAction.parental,
            extractAction: { if case .parental(let a) = $0 { a } else { nil } },
            challengeSource: .fixed(MathChallenge(left: 2, right: 3, op: .plus)),
            attemptLimit: 3,
            cooldown: .seconds(3600),
            now: { now }
        )
        let undo = UndoPlugin<GateUndoRoot, GateUndoAction>(isUndoable: isUndoable)
        let plugins = PluginHost<GateUndoRoot, GateUndoAction>()
        plugins.register(undo)
        plugins.register(gate)
        return Store(
            initialState: GateUndoRoot(),
            reducer: { state, action in
                switch action {
                case .draw: state.strokes += 1
                // HowToAddAParentalGate's re-lock recipe.
                case .didEnterBackground: state.parentalGate.passedReasons.removeAll()
                case .parental: break
                }
                return nil
            },
            plugins: plugins,
            undoPlugin: undo,
            isUndoable: isUndoable
        )
    }

    private static let onlyDrawing: @Sendable (GateUndoAction) -> Bool = {
        if case .draw = $0 { true } else { false }
    }

    @Test("Undo does not lift a cooldown")
    func undoKeepsCooldown() {
        let store = makeStore(isUndoable: Self.onlyDrawing)
        defer { store.cancelEffects() }

        store.send(.draw)
        store.send(.parental(.request(reason: "purchase")))
        for _ in 0..<3 { store.send(.parental(.submitAnswer(0))) }
        #expect(store.parentalGate.cooldownUntil != nil)

        store.undo()
        #expect(store.strokes == 0, "the app's own edit is still undone")

        store.send(.parental(.request(reason: "purchase")))
        store.send(.parental(.submitAnswer(5)))
        #expect(store.parentalGate.cooldownUntil != nil, "undo lifted the cooldown")
        #expect(!store.parentalGate.passedReasons.contains("purchase"), "gate passed during its cooldown")
    }

    @Test("Undo does not restore a pass the app re-locked")
    func undoKeepsRelock() {
        let store = makeStore(isUndoable: Self.onlyDrawing)
        defer { store.cancelEffects() }

        store.send(.parental(.request(reason: "purchase")))
        store.send(.parental(.submitAnswer(5)))
        #expect(store.parentalGate.passedReasons == ["purchase"])
        store.send(.draw)
        store.send(.didEnterBackground)

        store.undo()

        #expect(store.parentalGate.passedReasons.isEmpty, "undo restored a revoked pass")
    }

    @Test("Undoing each guess does not reset the attempt count")
    func undoingGuessesStillCountsThem() {
        // `UndoPlugin()`'s default predicate snapshots every action, the gate's
        // own included, so each wrong answer is itself undoable.
        let store = makeStore(isUndoable: { _ in true })
        defer { store.cancelEffects() }

        store.send(.parental(.request(reason: "purchase")))
        for _ in 0..<3 {
            store.send(.parental(.submitAnswer(0)))
            store.undo()
        }

        #expect(store.parentalGate.cooldownUntil != nil, "guess-then-undo never reached the limit")
    }
}
