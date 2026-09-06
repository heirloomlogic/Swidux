//
//  UndoPluginTests.swift
//  SwiduxTests
//

import Foundation
import Testing

@testable import Swidux

@Suite("UndoPlugin")
struct UndoPluginTests {
    // MARK: - Basic Undo/Redo

    @MainActor
    @Test("Undo restores previous state")
    func basicUndo() {
        let undo = UndoPlugin<TestState, TestAction>()
        let s0 = TestState()
        var s1 = TestState()
        let s1Entity = TestEntity(name: "added")
        s1.items[s1Entity.id] = s1Entity

        undo.willReduce(state: s0, action: .insert(TestEntity()))

        let restored = undo.undo(current: s1)
        #expect(restored == s0)
    }

    @MainActor
    @Test("Redo restores undone state")
    func basicRedo() {
        let undo = UndoPlugin<TestState, TestAction>()
        let s0 = TestState()
        var s1 = TestState()
        let s1Entity = TestEntity(name: "added")
        s1.items[s1Entity.id] = s1Entity

        undo.willReduce(state: s0, action: .insert(TestEntity()))

        let _ = undo.undo(current: s1)
        let restored = undo.redo(current: s0)
        #expect(restored == s1)
    }

    @MainActor
    @Test("Undo on empty stack returns nil")
    func undoEmpty() {
        let undo = UndoPlugin<TestState, TestAction>()
        #expect(undo.undo(current: TestState()) == nil)
        #expect(!undo.canUndo)
    }

    @MainActor
    @Test("Redo on empty stack returns nil")
    func redoEmpty() {
        let undo = UndoPlugin<TestState, TestAction>()
        #expect(undo.redo(current: TestState()) == nil)
        #expect(!undo.canRedo)
    }

    // MARK: - Multiple Steps

    @MainActor
    @Test("Multiple undos walk back through history")
    func multipleUndos() {
        let undo = UndoPlugin<TestState, TestAction>()
        var states: [TestState] = [TestState()]

        for i in 1...3 {
            undo.willReduce(state: states.last!, action: .insert(TestEntity(name: "step \(i)")))
            var next = states.last!
            let nextEntity = TestEntity(name: "step \(i)")
            next.items[nextEntity.id] = nextEntity
            states.append(next)
        }

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
        let undo = UndoPlugin<TestState, TestAction>()
        var states: [TestState] = [TestState()]

        for i in 1...3 {
            undo.willReduce(state: states.last!, action: .insert(TestEntity(name: "step \(i)")))
            var next = states.last!
            let nextEntity = TestEntity(name: "step \(i)")
            next.items[nextEntity.id] = nextEntity
            states.append(next)
        }

        var current = states[3]
        for _ in 0..<3 {
            current = undo.undo(current: current)!
        }
        #expect(current == states[0])

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
        let undo = UndoPlugin<TestState, TestAction>()
        let s0 = TestState()
        var s1 = TestState()
        let s1Entity = TestEntity(name: "first")
        s1.items[s1Entity.id] = s1Entity

        undo.willReduce(state: s0, action: .insert(TestEntity()))
        let _ = undo.undo(current: s1)
        #expect(undo.canRedo)

        undo.willReduce(state: s0, action: .insert(TestEntity()))
        #expect(!undo.canRedo)
    }

    // MARK: - canUndo / canRedo

    @MainActor
    @Test("canUndo and canRedo reflect stack state")
    func canUndoCanRedo() {
        let undo = UndoPlugin<TestState, TestAction>()
        #expect(!undo.canUndo)
        #expect(!undo.canRedo)

        undo.willReduce(state: TestState(), action: .noOp)
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
        let undo = UndoPlugin<TestState, TestAction>(maxDepth: 2)

        for i in 0..<5 {
            var state = TestState()
            let stateEntity = TestEntity(name: "step \(i)")
            state.items[stateEntity.id] = stateEntity
            undo.willReduce(state: state, action: .noOp)
        }

        #expect(undo.undo(current: TestState()) != nil)
        #expect(undo.undo(current: TestState()) != nil)
        #expect(undo.undo(current: TestState()) == nil)
    }

    // MARK: - Coalescing via Predicate

    @MainActor
    @Test("Consecutive coalescing actions share one undo entry")
    func coalescingGroupsKeystrokes() {
        let undo = UndoPlugin<TestState, TestAction>(
            coalescing: {
                if case .rename = $0 { return true }
                return false
            }
        )
        let s0 = TestState()
        let id = UUID()

        undo.willReduce(state: s0, action: .rename(id, "a"))
        undo.willReduce(state: s0, action: .rename(id, "ab"))
        undo.willReduce(state: s0, action: .rename(id, "abc"))

        #expect(undo.undo(current: s0) != nil)
        #expect(undo.undo(current: s0) == nil)
    }

    @MainActor
    @Test("Non-coalescing action after coalescing starts new entry")
    func coalescingThenNormal() {
        let id = UUID()
        let undo = UndoPlugin<TestState, TestAction>(
            coalescing: {
                if case .rename = $0 { return true }
                return false
            }
        )
        let s0 = TestState()
        var s1 = TestState()
        let s1Entity = TestEntity(name: "typed")
        s1.items[s1Entity.id] = s1Entity
        var s2 = TestState()
        let s2Entity = TestEntity(name: "incremented")
        s2.items[s2Entity.id] = s2Entity

        // Coalescing keystrokes
        undo.willReduce(state: s0, action: .rename(id, "a"))
        undo.willReduce(state: s0, action: .rename(id, "ab"))
        // Normal action
        undo.willReduce(state: s1, action: .insert(TestEntity()))

        #expect(undo.undo(current: s2) != nil)
        #expect(undo.undo(current: s1) != nil)
        #expect(undo.undo(current: s0) == nil)
    }

    @MainActor
    @Test("Coalescing after non-coalescing starts new coalesced entry")
    func normalThenCoalescing() {
        let id = UUID()
        let undo = UndoPlugin<TestState, TestAction>(
            coalescing: {
                if case .rename = $0 { return true }
                return false
            }
        )
        let s0 = TestState()
        var s1 = TestState()
        let s1Entity = TestEntity(name: "action")
        s1.items[s1Entity.id] = s1Entity

        undo.willReduce(state: s0, action: .insert(TestEntity()))
        undo.willReduce(state: s1, action: .rename(id, "a"))
        undo.willReduce(state: s1, action: .rename(id, "ab"))

        #expect(undo.undo(current: s1) != nil)
        #expect(undo.undo(current: s1) != nil)
        #expect(undo.undo(current: s0) == nil)
    }

    @MainActor
    @Test("Undo resets coalescing flag")
    func undoResetsCoalescing() {
        let id = UUID()
        let undo = UndoPlugin<TestState, TestAction>(
            coalescing: {
                if case .rename = $0 { return true }
                return false
            }
        )
        let s0 = TestState()

        undo.willReduce(state: s0, action: .rename(id, "a"))
        let _ = undo.undo(current: s0)

        undo.willReduce(state: s0, action: .rename(id, "b"))
        #expect(undo.canUndo)
    }

    @MainActor
    @Test("Redo resets coalescing flag")
    func redoResetsCoalescing() {
        let id = UUID()
        let undo = UndoPlugin<TestState, TestAction>(
            coalescing: {
                if case .rename = $0 { return true }
                return false
            }
        )
        let s0 = TestState()

        undo.willReduce(state: s0, action: .rename(id, "a"))
        let _ = undo.undo(current: s0)
        let _ = undo.redo(current: s0)

        undo.willReduce(state: s0, action: .rename(id, "b"))
        #expect(undo.undo(current: s0) != nil)
        #expect(undo.undo(current: s0) != nil)
    }

    // MARK: - isUndoable Predicate

    @MainActor
    @Test("Non-undoable actions are ignored")
    func isUndoableFilter() {
        let undo = UndoPlugin<TestState, TestAction>(
            isUndoable: {
                if case .noOp = $0 { return false }
                return true
            }
        )
        let s0 = TestState()

        undo.willReduce(state: s0, action: .noOp)
        #expect(!undo.canUndo)

        undo.willReduce(state: s0, action: .insert(TestEntity()))
        #expect(undo.canUndo)
    }

    @MainActor
    @Test("Plugin integrates with PluginHost")
    func pluginHostIntegration() {
        let undo = UndoPlugin<TestState, TestAction>()
        let host = PluginHost<TestState, TestAction>()
        host.register(undo)

        let s0 = TestState()
        host.willReduce(state: s0, action: .insert(TestEntity()))

        #expect(undo.canUndo)
        let restored = undo.undo(current: s0)
        #expect(restored == s0)
    }
}
