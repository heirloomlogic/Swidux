//
//  UndoMiddlewareTests.swift
//  SwiduxTests
//

import Foundation
import Testing

@testable import Swidux

@Suite("UndoMiddleware")
struct UndoMiddlewareTests {
    // MARK: - Basic Undo/Redo

    @MainActor
    @Test("Undo restores previous state")
    func basicUndo() {
        let undo = UndoMiddleware<TestState>()
        let s0 = TestState()
        var s1 = TestState()
        s1.items[UUID()] = TestEntity(name: "added")

        undo.willReduce(state: s0)
        // Reducer would produce s1 from s0

        let restored = undo.undo(current: s1)
        #expect(restored == s0)
    }

    @MainActor
    @Test("Redo restores undone state")
    func basicRedo() {
        let undo = UndoMiddleware<TestState>()
        let s0 = TestState()
        var s1 = TestState()
        s1.items[UUID()] = TestEntity(name: "added")

        undo.willReduce(state: s0)

        let _ = undo.undo(current: s1)
        let restored = undo.redo(current: s0)
        #expect(restored == s1)
    }

    @MainActor
    @Test("Undo on empty stack returns nil")
    func undoEmpty() {
        let undo = UndoMiddleware<TestState>()
        #expect(undo.undo(current: TestState()) == nil)
        #expect(!undo.canUndo)
    }

    @MainActor
    @Test("Redo on empty stack returns nil")
    func redoEmpty() {
        let undo = UndoMiddleware<TestState>()
        #expect(undo.redo(current: TestState()) == nil)
        #expect(!undo.canRedo)
    }

    // MARK: - Multiple Steps

    @MainActor
    @Test("Multiple undos walk back through history")
    func multipleUndos() {
        let undo = UndoMiddleware<TestState>()
        var states: [TestState] = [TestState()]

        for i in 1...3 {
            undo.willReduce(state: states.last!)
            var next = states.last!
            next.items[UUID()] = TestEntity(name: "step \(i)")
            states.append(next)
        }

        // Current is states[3], undo should walk back to states[0]
        var current = states[3]
        for i in stride(from: 2, through: 0, by: -1) {
            let restored = undo.undo(current: current)!
            #expect(restored == states[i])
            current = restored
        }

        #expect(!undo.canUndo)
    }

    @MainActor
    @Test("Multiple redos walk forward through history")
    func multipleRedos() {
        let undo = UndoMiddleware<TestState>()
        var states: [TestState] = [TestState()]

        for i in 1...3 {
            undo.willReduce(state: states.last!)
            var next = states.last!
            next.items[UUID()] = TestEntity(name: "step \(i)")
            states.append(next)
        }

        // Undo all 3
        var current = states[3]
        for _ in 0..<3 {
            current = undo.undo(current: current)!
        }
        #expect(current == states[0])

        // Redo all 3
        for i in 1...3 {
            let restored = undo.redo(current: current)!
            #expect(restored == states[i])
            current = restored
        }

        #expect(!undo.canRedo)
    }

    // MARK: - Redo Cleared on New Action

    @MainActor
    @Test("New action clears redo stack")
    func newActionClearsRedo() {
        let undo = UndoMiddleware<TestState>()
        let s0 = TestState()
        var s1 = TestState()
        s1.items[UUID()] = TestEntity(name: "first")

        undo.willReduce(state: s0)
        let _ = undo.undo(current: s1)
        #expect(undo.canRedo)

        // New action should clear redo
        undo.willReduce(state: s0)
        #expect(!undo.canRedo)
    }

    // MARK: - canUndo / canRedo

    @MainActor
    @Test("canUndo and canRedo reflect stack state")
    func canUndoCanRedo() {
        let undo = UndoMiddleware<TestState>()
        #expect(!undo.canUndo)
        #expect(!undo.canRedo)

        undo.willReduce(state: TestState())
        #expect(undo.canUndo)
        #expect(!undo.canRedo)

        let _ = undo.undo(current: TestState())
        #expect(!undo.canUndo)
        #expect(undo.canRedo)
    }

    // MARK: - Max Depth

    @MainActor
    @Test("Max depth limits undo stack size")
    func maxDepth() {
        let undo = UndoMiddleware<TestState>(maxDepth: 2)

        for i in 0..<5 {
            var state = TestState()
            state.items[UUID()] = TestEntity(name: "step \(i)")
            undo.willReduce(state: state)
        }

        // Only 2 undos should be available
        #expect(undo.undo(current: TestState()) != nil)
        #expect(undo.undo(current: TestState()) != nil)
        #expect(undo.undo(current: TestState()) == nil)
    }

    // MARK: - Coalescing

    @MainActor
    @Test("Consecutive coalescing calls share one undo entry")
    func coalescingGroupsKeystrokes() {
        let undo = UndoMiddleware<TestState>()
        let s0 = TestState()

        // Simulate typing: first keystroke pushes, rest skip
        undo.willReduce(state: s0, coalescing: true)
        undo.willReduce(state: s0, coalescing: true)
        undo.willReduce(state: s0, coalescing: true)

        // Only one undo entry
        #expect(undo.undo(current: s0) != nil)
        #expect(undo.undo(current: s0) == nil)
    }

    @MainActor
    @Test("Non-coalescing action after coalescing starts new entry")
    func coalescingThenNormal() {
        let undo = UndoMiddleware<TestState>()
        let s0 = TestState()
        var s1 = TestState()
        s1.items[UUID()] = TestEntity(name: "typed")
        var s2 = TestState()
        s2.items[UUID()] = TestEntity(name: "incremented")

        // Coalescing keystrokes
        undo.willReduce(state: s0, coalescing: true)
        undo.willReduce(state: s0, coalescing: true)
        // Normal action
        undo.willReduce(state: s1)

        // Two undo entries: one for the coalesced keystrokes, one for the normal action
        #expect(undo.undo(current: s2) != nil)  // undoes normal action
        #expect(undo.undo(current: s1) != nil)  // undoes coalesced keystrokes
        #expect(undo.undo(current: s0) == nil)  // stack empty
    }

    @MainActor
    @Test("Coalescing after non-coalescing starts new coalesced entry")
    func normalThenCoalescing() {
        let undo = UndoMiddleware<TestState>()
        let s0 = TestState()
        var s1 = TestState()
        s1.items[UUID()] = TestEntity(name: "action")

        // Normal action
        undo.willReduce(state: s0)
        // Start coalescing
        undo.willReduce(state: s1, coalescing: true)
        undo.willReduce(state: s1, coalescing: true)

        // Two entries
        #expect(undo.undo(current: s1) != nil)
        #expect(undo.undo(current: s1) != nil)
        #expect(undo.undo(current: s0) == nil)
    }

    @MainActor
    @Test("Undo resets coalescing flag")
    func undoResetsCoalescing() {
        let undo = UndoMiddleware<TestState>()
        let s0 = TestState()

        undo.willReduce(state: s0, coalescing: true)
        let _ = undo.undo(current: s0)

        // Next coalescing call should push (not skip)
        undo.willReduce(state: s0, coalescing: true)
        #expect(undo.canUndo)
    }

    @MainActor
    @Test("Redo resets coalescing flag")
    func redoResetsCoalescing() {
        let undo = UndoMiddleware<TestState>()
        let s0 = TestState()

        undo.willReduce(state: s0, coalescing: true)
        let _ = undo.undo(current: s0)
        let _ = undo.redo(current: s0)

        // Next coalescing call should push (not skip)
        undo.willReduce(state: s0, coalescing: true)
        // Two entries now: original + new coalesced
        #expect(undo.undo(current: s0) != nil)
        #expect(undo.undo(current: s0) != nil)
    }
}
