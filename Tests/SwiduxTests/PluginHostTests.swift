//
//  PluginHostTests.swift
//  SwiduxTests
//
//  Tests for SwiduxPlugin protocol and PluginHost lifecycle.
//

import Swidux
import Testing

@MainActor
@Suite("PluginHost")
struct PluginHostTests {
    // MARK: - Spy Plugin

    final class SpyPlugin: SwiduxPlugin {
        var willReduceCalls: [(state: TestState, action: TestAction)] = []
        var reduceCalls: [TestAction] = []
        var afterReduceCalls: [TestAction] = []
        var flushCount = 0

        let effectToReturn: Effect<TestAction>?
        let label: String

        init(label: String = "spy", effect: Effect<TestAction>? = nil) {
            self.label = label
            self.effectToReturn = effect
        }

        func willReduce(state: TestState, action: TestAction) {
            willReduceCalls.append((state, action))
        }

        func reduce(state: inout TestState, action: TestAction) -> Effect<TestAction>? {
            reduceCalls.append(action)
            return effectToReturn
        }

        func afterReduce(state: inout TestState, action: TestAction) {
            afterReduceCalls.append(action)
        }

        func flush() async {
            flushCount += 1
        }
    }

    // MARK: - Registration

    @Test("register appends plugins in order")
    func registerOrder() {
        let host = PluginHost<TestState, TestAction>()
        let a = SpyPlugin(label: "a")
        let b = SpyPlugin(label: "b")

        host.register(a)
        host.register(b)

        #expect(host.plugins.count == 2)
    }

    @Test("empty host has no plugins")
    func emptyHost() {
        let host = PluginHost<TestState, TestAction>()
        #expect(host.plugins.isEmpty)
    }

    // MARK: - Lifecycle Ordering

    @Test("willReduce calls all plugins in order")
    func willReduceOrder() {
        let host = PluginHost<TestState, TestAction>()

        let a = SpyPlugin(label: "a")
        let b = SpyPlugin(label: "b")

        host.register(a)
        host.register(b)

        let state = TestState()
        host.willReduce(state: state, action: .noOp)

        #expect(a.willReduceCalls.count == 1)
        #expect(b.willReduceCalls.count == 1)
    }

    @Test("afterReduce calls all plugins in order")
    func afterReduceOrder() {
        let host = PluginHost<TestState, TestAction>()
        let a = SpyPlugin(label: "a")
        let b = SpyPlugin(label: "b")

        host.register(a)
        host.register(b)

        var state = TestState()
        host.afterReduce(state: &state, action: .noOp)

        #expect(a.afterReduceCalls.count == 1)
        #expect(b.afterReduceCalls.count == 1)
    }

    // MARK: - Reduce + Effect Collection

    @Test("reduce collects non-nil effects")
    func reduceCollectsEffects() {
        let host = PluginHost<TestState, TestAction>()
        let withEffect = SpyPlugin(label: "with", effect: Effect { _ in })
        let withoutEffect = SpyPlugin(label: "without", effect: nil)

        host.register(withEffect)
        host.register(withoutEffect)

        var state = TestState()
        let effects = host.reduce(state: &state, action: .noOp)

        #expect(effects.count == 1)
    }

    @Test("reduce returns empty array when no plugins return effects")
    func reduceNoEffects() {
        let host = PluginHost<TestState, TestAction>()
        let a = SpyPlugin(label: "a")

        host.register(a)

        var state = TestState()
        let effects = host.reduce(state: &state, action: .noOp)

        #expect(effects.isEmpty)
    }

    @Test("reduce with no plugins returns empty")
    func reduceEmptyHost() {
        let host = PluginHost<TestState, TestAction>()
        var state = TestState()

        let effects = host.reduce(state: &state, action: .noOp)
        #expect(effects.isEmpty)
    }

    // MARK: - State Mutation

    @Test("reduce passes mutable state through plugins sequentially")
    func reduceMutatesState() {
        let host = PluginHost<TestState, TestAction>()
        let entity = TestEntity(name: "test")

        final class InsertPlugin: SwiduxPlugin {
            let entity: TestEntity
            init(entity: TestEntity) { self.entity = entity }

            func reduce(
                state: inout TestState, action: TestAction
            ) -> Effect<TestAction>? {
                if case .insert = action {
                    state.items[entity.id] = entity
                }
                return nil
            }
        }

        host.register(InsertPlugin(entity: entity))

        var state = TestState()
        _ = host.reduce(state: &state, action: .insert(entity))

        #expect(state.items.count == 1)
        #expect(state.items[entity.id]?.name == "test")
    }

    // MARK: - Flush

    @Test("flush calls all plugins")
    func flushAll() async {
        let host = PluginHost<TestState, TestAction>()
        let a = SpyPlugin(label: "a")
        let b = SpyPlugin(label: "b")

        host.register(a)
        host.register(b)

        await host.flush()

        #expect(a.flushCount == 1)
        #expect(b.flushCount == 1)
    }

    // MARK: - Default Implementations

    @Test("plugin with only willReduce implemented works")
    func partialConformance() {
        final class WillReduceOnly: SwiduxPlugin {
            var called = false
            func willReduce(state: TestState, action: TestAction) {
                called = true
            }
        }

        let host = PluginHost<TestState, TestAction>()
        let plugin = WillReduceOnly()
        host.register(plugin)

        let state = TestState()
        host.willReduce(state: state, action: .noOp)

        var mutableState = TestState()
        let effects = host.reduce(state: &mutableState, action: .noOp)
        host.afterReduce(state: &mutableState, action: .noOp)

        #expect(plugin.called)
        #expect(effects.isEmpty)
    }
}
