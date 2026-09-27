//
//  SwiduxMacroCompiledTests.swift
//  SwiduxTests
//
//  `@Swidux` applied in a compiled target. `SwiduxMacrosTests` asserts the text
//  the macro emits, and `assertMacroExpansion` never type-checks it — so a
//  generated call that resolves to the wrong overload, or a property the
//  generator silently skipped, passes there and fails only here.
//

import Foundation
import Testing

@testable import Swidux

// MARK: - Fixtures

typealias RestoreProbeItems = EntityStore<TestEntity>

/// The same `EntityStore` spelled three ways. Only the resolved type may decide
/// how undo restores it: an alias or a module qualifier is still an entity store.
@Swidux
nonisolated struct RestoreSpellingState: Equatable, Sendable {
    var direct: EntityStore<TestEntity> = .init()
    var aliased: RestoreProbeItems = .init()
    var qualified: Swidux.EntityStore<TestEntity> = .init()
}

/// A stored property with an observer is still stored, and must survive a pack.
@Swidux
nonisolated struct ObservedPropertyState: Equatable, Sendable {
    var plain: Int = 0
    var clamped: Int = 0 {
        didSet { if clamped < 0 { clamped = 0 } }
    }
    var watched: String = "" {
        willSet {}
    }
}

/// Type-level members are not state.
@Swidux
nonisolated struct CountedState: Equatable, Sendable {
    nonisolated(unsafe) static var instances: Int = 0
    static let limit: Int = 3

    var count: Int = 0
}

/// Opts out of undo restoration, like every plugin-owned slice.
@Swidux
nonisolated struct PinnedState: Equatable, Sendable {
    static var restoresOnUndo: Bool { false }

    var value: Int = 0
}

@Swidux
nonisolated struct RestorableChild: Equatable, Sendable {
    var value: Int = 0
}

/// The opt-out holds however the type is mounted: `@Slice` or a plain leaf.
@Swidux
nonisolated struct RestoreOptOutRoot: Equatable, Sendable {
    @Slice var pinnedSlice: PinnedState = .init()
    var pinnedLeaf: PinnedState = .init()
    @Slice var child: RestorableChild = .init()
    var document: Int = 0
}

/// A state nested in another type, as a feature namespace would hold it.
enum NestingFeature {
    @Swidux
    nonisolated struct State: Equatable, Sendable {
        var count: Int = 0
    }
}

/// Members narrower than the struct stay narrow on the observer; a private one
/// must still compile, as `fileprivate`, and still round-trip.
@Swidux
public nonisolated struct AccessMixState: Equatable, Sendable {
    /// Public, so the observer mirrors it as public.
    public var shown: Int = 0
    var hidden: Int = 0
    private var secret: Int = 0

    mutating func setSecret(_ value: Int) { secret = value }
}

/// A property observer with a side effect on a sibling. Undo must reproduce the
/// snapshot exactly, so restoring `title` must not run its `didSet`.
@Swidux
nonisolated struct StampedState: Equatable, Sendable {
    var revision: Int = 0
    var title: String = "" {
        didSet { revision += 1 }
    }
    var log: [String] = [] {
        willSet { if log.count > 100 { log.removeAll() } }
    }
}

/// An opted-out type mounted optionally or in an array is still opted out.
@Swidux
nonisolated struct WrappedPinParent: Equatable, Sendable {
    var maybePinned: PinnedState? = nil
    var pinnedList: [PinnedState] = []
    var maybeChild: RestorableChild? = nil
    var children: [RestorableChild] = []
}

/// Top-level `private` (the same scope as `fileprivate` there), the usual shape
/// of a state in a test or preview file.
@Swidux
private nonisolated struct FileScopedState: Equatable, Sendable {
    var count: Int = 0
}

// MARK: - Tests

@Suite("@Swidux compiled expansion")
@MainActor
struct SwiduxMacroCompiledTests {
    /// A store populated with `entity` whose change set has already been drained,
    /// as every snapshot's is by the time undo hands it back.
    private func drainedStore(holding entity: TestEntity) -> EntityStore<TestEntity> {
        var store = EntityStore<TestEntity>()
        store[entity.id] = entity
        store.resetChanges()
        return store
    }

    @Test("applyRestore records an EntityStore's changes however its type is spelled")
    func entityStoreRestoreIgnoresSpelling() {
        let item = TestEntity(name: "a")
        let snapshot = RestoreSpellingState(
            direct: drainedStore(holding: item),
            aliased: drainedStore(holding: item),
            qualified: drainedStore(holding: item)
        )
        var current = RestoreSpellingState()

        RestoreSpellingState.applyRestore(from: snapshot, to: &current)

        // A plain assignment would adopt the snapshot's drained change set, so
        // the restored row would never reach the persistence plugin.
        #expect(current.direct.changes.upserts == [item.id])
        #expect(current.aliased.changes.upserts == [item.id])
        #expect(current.qualified.changes.upserts == [item.id])
    }

    @Test("applyRestore keeps a type that opts out, @Slice or not, and restores the rest")
    func restoreSkipsOptedOutTypes() {
        let snapshot = RestoreOptOutRoot(
            pinnedSlice: .init(value: 1),
            pinnedLeaf: .init(value: 1),
            child: .init(value: 1),
            document: 1
        )
        var current = RestoreOptOutRoot(
            pinnedSlice: .init(value: 2),
            pinnedLeaf: .init(value: 2),
            child: .init(value: 2),
            document: 2
        )

        RestoreOptOutRoot.applyRestore(from: snapshot, to: &current)

        #expect(current.pinnedSlice.value == 2)
        #expect(current.pinnedLeaf.value == 2)
        #expect(current.child.value == 1)
        #expect(current.document == 1)
    }

    @Test("A property with willSet/didSet survives dispatch")
    func observedPropertySurvivesDispatch() {
        let store = Store<ObservedPropertyState, Int>(
            initialState: .init(),
            reducer: { state, value in
                state.clamped = value
                state.watched = "\(value)"
                return nil
            }
        )

        store.send(5)
        store.send(5)

        let packed = ObservedPropertyState(observer: store.observer)
        #expect(packed.clamped == 5)
        #expect(packed.watched == "5")
    }

    @Test("Static members are not mirrored onto the observer")
    func staticMembersAreSkipped() {
        let state = CountedState(count: CountedState.limit)

        #expect(CountedState(observer: CountedState.makeObserver(from: state)) == state)
    }

    @Test("A state nested in another type conforms under its qualified name")
    func nestedStateConforms() {
        let state = NestingFeature.State(count: 3)
        let observer: NestingFeature.StateObserver = NestingFeature.State.makeObserver(from: state)

        #expect(NestingFeature.State(observer: observer) == state)
    }

    @Test("Narrower members, private included, round-trip through the observer")
    func narrowMembersRoundTrip() {
        var state = AccessMixState(shown: 1, hidden: 2)
        state.setSecret(3)

        #expect(AccessMixState(observer: AccessMixState.makeObserver(from: state)) == state)
    }

    @Test("applyRestore reproduces the snapshot without running property observers")
    func restoreDoesNotRunObservers() {
        let snapshot = StampedState(revision: 5, title: "before", log: ["a"])
        var current = StampedState(revision: 9, title: "after", log: ["a", "b"])

        StampedState.applyRestore(from: snapshot, to: &current)

        #expect(current == snapshot, "restored revision \(current.revision), snapshot had 5")
    }

    @Test("An opted-out type is kept through Optional and Array; a restorable one is restored")
    func optOutHoldsThroughWrappers() {
        let snapshot = WrappedPinParent(maybeChild: .init(value: 1), children: [.init(value: 1)])
        var current = WrappedPinParent(
            maybePinned: .init(value: 7),
            pinnedList: [.init(value: 7)],
            maybeChild: .init(value: 2),
            children: [.init(value: 2), .init(value: 3)]
        )

        WrappedPinParent.applyRestore(from: snapshot, to: &current)

        #expect(current.maybePinned == .init(value: 7), "opted-out state rolled back through Optional")
        #expect(current.pinnedList == [.init(value: 7)], "opted-out state rolled back through Array")
        #expect(current.maybeChild == .init(value: 1))
        #expect(current.children == [.init(value: 1)])
    }

    @Test("A top-level fileprivate state works through a store")
    func fileprivateStateDispatches() {
        let store = Store<FileScopedState, Int>(
            initialState: .init(),
            reducer: { state, value in
                state.count += value
                return nil
            }
        )

        store.send(2)

        #expect(FileScopedState(observer: store.observer).count == 2)
    }
}
