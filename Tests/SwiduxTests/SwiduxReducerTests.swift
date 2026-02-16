//
//  SwiduxReducerTests.swift
//  SwiduxTests
//

import Foundation
import Testing

@testable import Swidux

// MARK: - Concrete Test Reducer

/// A reducer that handles TestAction against TestState.
struct TestReducer: SwiduxReducer {
    func reduce(
        state: inout TestState,
        action: TestAction,
        environment: TestEnvironment
    ) -> Effect<TestAction>? {
        switch action {
        case .insert(let entity):
            state.items[entity.id] = entity

        case .delete(let id):
            state.items[id] = nil

        case .rename(let id, let newName):
            state.items.modify(id) { $0.name = newName }

        case .noOp:
            break

        case .effectAction:
            break
        }

        // Return an effect only for .insert (to test the effect path)
        if case .insert(let entity) = action {
            return { send in
                await send(.effectAction("inserted \(entity.name)"))
            }
        }
        return nil
    }
}

// MARK: - Tests

@Suite("SwiduxReducer")
struct SwiduxReducerTests {
    let reducer = TestReducer()
    let env = TestEnvironment()

    @Test("Reduce inserts entity and returns an effect")
    func reduceInsert() async {
        var state = TestState()
        let entity = TestEntity(name: "Hello")

        let effect = reducer.reduce(state: &state, action: .insert(entity), environment: env)

        #expect(state.items[entity.id]?.name == "Hello")
        #expect(effect != nil)

        // Execute the effect and verify the dispatched action
        var dispatched: TestAction?
        await effect! { action in
            dispatched = action
        }
        #expect(dispatched == .effectAction("inserted Hello"))
    }

    @Test("Reduce deletes entity and returns nil")
    func reduceDelete() {
        let entity = TestEntity(name: "Doomed")
        var state = TestState()
        state.items = EntityStore([entity])

        let effect = reducer.reduce(state: &state, action: .delete(entity.id), environment: env)

        #expect(state.items[entity.id] == nil)
        #expect(effect == nil)
    }

    @Test("Reduce renames entity and returns nil")
    func reduceRename() {
        let entity = TestEntity(name: "Old")
        var state = TestState()
        state.items = EntityStore([entity])

        let effect = reducer.reduce(
            state: &state,
            action: .rename(entity.id, "New"),
            environment: env
        )

        #expect(state.items[entity.id]?.name == "New")
        #expect(effect == nil)
    }

    @Test("Reduce noOp returns nil and state unchanged")
    func reduceNoOp() {
        var state = TestState()
        let effect = reducer.reduce(state: &state, action: .noOp, environment: env)

        #expect(state.items.isEmpty)
        #expect(effect == nil)
    }
}
