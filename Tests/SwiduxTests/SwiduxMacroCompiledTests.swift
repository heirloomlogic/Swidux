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
}
