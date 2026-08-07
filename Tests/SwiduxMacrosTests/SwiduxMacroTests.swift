import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

// Macro implementations build for the host (macOS) only; when this test
// bundle compiles for another destination (the iOS-simulator CI job), the
// whole file must drop out, not just the import.
#if canImport(SwiduxMacros)
import SwiduxMacros

// MARK: - @Slice Marker

final class SliceMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Slice": SliceMacro.self
    ]

    func testNestedGeneratesNothing() throws {
        assertMacroExpansion(
            """
            struct Parent {
                @Slice var ui: UIState = .init()
            }
            """,
            expandedSource: """
                struct Parent {
                    var ui: UIState = .init()
                }
                """,
            macros: macros
        )
    }
}

// MARK: - @Swidux

final class SwiduxMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Swidux": SwiduxMacro.self,
        "Slice": SliceMacro.self,
    ]

    // MARK: Leaf Properties

    func testSingleLeafProperty() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct SimpleState: Equatable, Sendable {
                var count: Int = 0
            }
            """,
            expandedSource: """
                struct SimpleState: Equatable, Sendable {
                    var count: Int = 0
                }

                @Observable
                @MainActor
                final class SimpleStateObserver: @unchecked Sendable {
                    var count: Int

                    init(count: Int = 0) {
                        self.count = count
                    }
                }

                extension SimpleState: SwiduxObservable {
                    typealias Observer = SimpleStateObserver

                    @MainActor
                    init(observer: SimpleStateObserver) {
                        self.count = observer.count
                    }

                    @MainActor
                    static func makeObserver(from state: SimpleState) -> SimpleStateObserver {
                        SimpleStateObserver(
                            count: state.count
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: SimpleState, to observer: SimpleStateObserver) {
                        observer.count = snapshot.count
                    }

                    @MainActor
                    static func applyRestore(from snapshot: SimpleState, to current: inout SimpleState) {
                        current.count = snapshot.count
                    }
                }
                """,
            macros: macros
        )
    }

    func testMultipleLeafProperties() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct MultiState: Equatable, Sendable {
                var name: String = ""
                var age: Int = 0
                var isActive: Bool = false
            }
            """,
            expandedSource: """
                struct MultiState: Equatable, Sendable {
                    var name: String = ""
                    var age: Int = 0
                    var isActive: Bool = false
                }

                @Observable
                @MainActor
                final class MultiStateObserver: @unchecked Sendable {
                    var name: String
                    var age: Int
                    var isActive: Bool

                    init(name: String = "", age: Int = 0, isActive: Bool = false) {
                        self.name = name
                        self.age = age
                        self.isActive = isActive
                    }
                }

                extension MultiState: SwiduxObservable {
                    typealias Observer = MultiStateObserver

                    @MainActor
                    init(observer: MultiStateObserver) {
                        self.name = observer.name
                        self.age = observer.age
                        self.isActive = observer.isActive
                    }

                    @MainActor
                    static func makeObserver(from state: MultiState) -> MultiStateObserver {
                        MultiStateObserver(
                            name: state.name,
                            age: state.age,
                            isActive: state.isActive
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: MultiState, to observer: MultiStateObserver) {
                        observer.name = snapshot.name
                        observer.age = snapshot.age
                        observer.isActive = snapshot.isActive
                    }

                    @MainActor
                    static func applyRestore(from snapshot: MultiState, to current: inout MultiState) {
                        current.name = snapshot.name
                        current.age = snapshot.age
                        current.isActive = snapshot.isActive
                    }
                }
                """,
            macros: macros
        )
    }

    // MARK: EntityStore Properties

    func testEntityStoreProperty() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct StoreState: Equatable, Sendable {
                var items: EntityStore<Item> = .init()
            }
            """,
            expandedSource: """
                struct StoreState: Equatable, Sendable {
                    var items: EntityStore<Item> = .init()
                }

                @Observable
                @MainActor
                final class StoreStateObserver: @unchecked Sendable {
                    var items: EntityStore<Item>

                    init(items: EntityStore<Item> = .init()) {
                        self.items = items
                    }
                }

                extension StoreState: SwiduxObservable {
                    typealias Observer = StoreStateObserver

                    @MainActor
                    init(observer: StoreStateObserver) {
                        self.items = observer.items
                    }

                    @MainActor
                    static func makeObserver(from state: StoreState) -> StoreStateObserver {
                        StoreStateObserver(
                            items: state.items
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: StoreState, to observer: StoreStateObserver) {
                        observer.items = snapshot.items
                    }

                    @MainActor
                    static func applyRestore(from snapshot: StoreState, to current: inout StoreState) {
                        current.items.restore(from: snapshot.items)
                    }
                }
                """,
            macros: macros
        )
    }

    func testMultipleEntityStores() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct MultiEntityState: Equatable, Sendable {
                var decks: EntityStore<Deck> = .init()
                var cards: EntityStore<Card> = .init()
            }
            """,
            expandedSource: """
                struct MultiEntityState: Equatable, Sendable {
                    var decks: EntityStore<Deck> = .init()
                    var cards: EntityStore<Card> = .init()
                }

                @Observable
                @MainActor
                final class MultiEntityStateObserver: @unchecked Sendable {
                    var decks: EntityStore<Deck>
                    var cards: EntityStore<Card>

                    init(decks: EntityStore<Deck> = .init(), cards: EntityStore<Card> = .init()) {
                        self.decks = decks
                        self.cards = cards
                    }
                }

                extension MultiEntityState: SwiduxObservable {
                    typealias Observer = MultiEntityStateObserver

                    @MainActor
                    init(observer: MultiEntityStateObserver) {
                        self.decks = observer.decks
                        self.cards = observer.cards
                    }

                    @MainActor
                    static func makeObserver(from state: MultiEntityState) -> MultiEntityStateObserver {
                        MultiEntityStateObserver(
                            decks: state.decks,
                            cards: state.cards
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: MultiEntityState, to observer: MultiEntityStateObserver) {
                        observer.decks = snapshot.decks
                        observer.cards = snapshot.cards
                    }

                    @MainActor
                    static func applyRestore(from snapshot: MultiEntityState, to current: inout MultiEntityState) {
                        current.decks.restore(from: snapshot.decks)
                        current.cards.restore(from: snapshot.cards)
                    }
                }
                """,
            macros: macros
        )
    }

    // MARK: Nested Properties

    func testNestedProperty() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct ParentState: Equatable, Sendable {
                var count: Int = 0
                @Slice var child: ChildState = .init()
            }
            """,
            expandedSource: """
                struct ParentState: Equatable, Sendable {
                    var count: Int = 0
                    var child: ChildState = .init()
                }

                @Observable
                @MainActor
                final class ParentStateObserver: @unchecked Sendable {
                    var count: Int
                    let child: ChildStateObserver

                    init(count: Int = 0, child: ChildStateObserver = ChildStateObserver()) {
                        self.count = count
                        self.child = child
                    }
                }

                extension ParentState: SwiduxObservable {
                    typealias Observer = ParentStateObserver

                    @MainActor
                    init(observer: ParentStateObserver) {
                        self.count = observer.count
                        self.child = ChildState(observer: observer.child)
                    }

                    @MainActor
                    static func makeObserver(from state: ParentState) -> ParentStateObserver {
                        ParentStateObserver(
                            count: state.count,
                            child: ChildState.makeObserver(from: state.child)
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: ParentState, to observer: ParentStateObserver) {
                        observer.count = snapshot.count
                        ChildState.apply(snapshot.child, to: observer.child)
                    }

                    @MainActor
                    static func applyRestore(from snapshot: ParentState, to current: inout ParentState) {
                        current.count = snapshot.count
                        ChildState.applyRestore(from: snapshot.child, to: &current.child)
                    }
                }
                """,
            macros: macros
        )
    }

    // MARK: Mixed (Full AppState Pattern)

    func testMixedProperties_fullAppStatePattern() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct AppState: Equatable, Sendable {
                var counters: EntityStore<Counter> = .init()
                @Slice var ui: UIState = .init()
            }
            """,
            expandedSource: """
                struct AppState: Equatable, Sendable {
                    var counters: EntityStore<Counter> = .init()
                    var ui: UIState = .init()
                }

                @Observable
                @MainActor
                final class AppStateObserver: @unchecked Sendable {
                    var counters: EntityStore<Counter>
                    let ui: UIStateObserver

                    init(counters: EntityStore<Counter> = .init(), ui: UIStateObserver = UIStateObserver()) {
                        self.counters = counters
                        self.ui = ui
                    }
                }

                extension AppState: SwiduxObservable {
                    typealias Observer = AppStateObserver

                    @MainActor
                    init(observer: AppStateObserver) {
                        self.counters = observer.counters
                        self.ui = UIState(observer: observer.ui)
                    }

                    @MainActor
                    static func makeObserver(from state: AppState) -> AppStateObserver {
                        AppStateObserver(
                            counters: state.counters,
                            ui: UIState.makeObserver(from: state.ui)
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: AppState, to observer: AppStateObserver) {
                        observer.counters = snapshot.counters
                        UIState.apply(snapshot.ui, to: observer.ui)
                    }

                    @MainActor
                    static func applyRestore(from snapshot: AppState, to current: inout AppState) {
                        current.counters.restore(from: snapshot.counters)
                        UIState.applyRestore(from: snapshot.ui, to: &current.ui)
                    }
                }
                """,
            macros: macros
        )
    }

    // MARK: Diagnostics

    func testNonStructEmitsDiagnostic() throws {
        assertMacroExpansion(
            """
            @Swidux
            class BadClass {}
            """,
            expandedSource: """
                class BadClass {}
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Swidux can only be applied to structs",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testInferredTypeEmitsDiagnostic() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct SkippedState: Equatable, Sendable {
                var count: Int = 0
                var flag = false
            }
            """,
            expandedSource: """
                struct SkippedState: Equatable, Sendable {
                    var count: Int = 0
                    var flag = false
                }

                @Observable
                @MainActor
                final class SkippedStateObserver: @unchecked Sendable {
                    var count: Int

                    init(count: Int = 0) {
                        self.count = count
                    }
                }

                extension SkippedState: SwiduxObservable {
                    typealias Observer = SkippedStateObserver

                    @MainActor
                    init(observer: SkippedStateObserver) {
                        self.count = observer.count
                    }

                    @MainActor
                    static func makeObserver(from state: SkippedState) -> SkippedStateObserver {
                        SkippedStateObserver(
                            count: state.count
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: SkippedState, to observer: SkippedStateObserver) {
                        observer.count = snapshot.count
                    }

                    @MainActor
                    static func applyRestore(from snapshot: SkippedState, to current: inout SkippedState) {
                        current.count = snapshot.count
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Stored properties need an explicit type annotation (var name: Type = …); a property with an inferred type is invisible to the macro, so its value would silently reset instead of being observed/persisted",
                    line: 4,
                    column: 9
                )
            ],
            macros: macros
        )
    }

    func testMultipleBindingsEmitDiagnostic() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct CombinedState: Equatable, Sendable {
                var count: Int = 0
                var a, b: Int
            }
            """,
            expandedSource: """
                struct CombinedState: Equatable, Sendable {
                    var count: Int = 0
                    var a, b: Int
                }

                @Observable
                @MainActor
                final class CombinedStateObserver: @unchecked Sendable {
                    var count: Int

                    init(count: Int = 0) {
                        self.count = count
                    }
                }

                extension CombinedState: SwiduxObservable {
                    typealias Observer = CombinedStateObserver

                    @MainActor
                    init(observer: CombinedStateObserver) {
                        self.count = observer.count
                    }

                    @MainActor
                    static func makeObserver(from state: CombinedState) -> CombinedStateObserver {
                        CombinedStateObserver(
                            count: state.count
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: CombinedState, to observer: CombinedStateObserver) {
                        observer.count = snapshot.count
                    }

                    @MainActor
                    static func applyRestore(from snapshot: CombinedState, to current: inout CombinedState) {
                        current.count = snapshot.count
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Declare each stored property separately (var a: Int; var b: Int); only the first binding of a combined declaration is visible to the macro, so the rest would silently reset instead of being observed/persisted",
                    line: 4,
                    column: 5
                )
            ],
            macros: macros
        )
    }

    func testComputedAndStaticPropertiesAreNotDiagnosed() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct QuietState: Equatable, Sendable {
                var count: Int = 0
                static let shared = QuietState()
                var doubled: Int { count * 2 }
            }
            """,
            expandedSource: """
                struct QuietState: Equatable, Sendable {
                    var count: Int = 0
                    static let shared = QuietState()
                    var doubled: Int { count * 2 }
                }

                @Observable
                @MainActor
                final class QuietStateObserver: @unchecked Sendable {
                    var count: Int

                    init(count: Int = 0) {
                        self.count = count
                    }
                }

                extension QuietState: SwiduxObservable {
                    typealias Observer = QuietStateObserver

                    @MainActor
                    init(observer: QuietStateObserver) {
                        self.count = observer.count
                    }

                    @MainActor
                    static func makeObserver(from state: QuietState) -> QuietStateObserver {
                        QuietStateObserver(
                            count: state.count
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: QuietState, to observer: QuietStateObserver) {
                        observer.count = snapshot.count
                    }

                    @MainActor
                    static func applyRestore(from snapshot: QuietState, to current: inout QuietState) {
                        current.count = snapshot.count
                    }
                }
                """,
            macros: macros
        )
    }

    // MARK: Edge Cases

    func testPropertyWithNoDefault() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct NoDefaultState: Equatable, Sendable {
                var name: String
            }
            """,
            expandedSource: """
                struct NoDefaultState: Equatable, Sendable {
                    var name: String
                }

                @Observable
                @MainActor
                final class NoDefaultStateObserver: @unchecked Sendable {
                    var name: String

                    init(name: String) {
                        self.name = name
                    }
                }

                extension NoDefaultState: SwiduxObservable {
                    typealias Observer = NoDefaultStateObserver

                    @MainActor
                    init(observer: NoDefaultStateObserver) {
                        self.name = observer.name
                    }

                    @MainActor
                    static func makeObserver(from state: NoDefaultState) -> NoDefaultStateObserver {
                        NoDefaultStateObserver(
                            name: state.name
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: NoDefaultState, to observer: NoDefaultStateObserver) {
                        observer.name = snapshot.name
                    }

                    @MainActor
                    static func applyRestore(from snapshot: NoDefaultState, to current: inout NoDefaultState) {
                        current.name = snapshot.name
                    }
                }
                """,
            macros: macros
        )
    }

    func testPublicAccessControl() throws {
        assertMacroExpansion(
            """
            @Swidux
            public struct PublicState: Equatable, Sendable {
                var count: Int = 0
            }
            """,
            expandedSource: """
                public struct PublicState: Equatable, Sendable {
                    var count: Int = 0
                }

                @Observable
                @MainActor
                public final class PublicStateObserver: @unchecked Sendable {
                    public var count: Int

                    public init(count: Int = 0) {
                        self.count = count
                    }
                }

                extension PublicState: SwiduxObservable {
                    public typealias Observer = PublicStateObserver

                    @MainActor
                    public init(observer: PublicStateObserver) {
                        self.count = observer.count
                    }

                    @MainActor
                    public static func makeObserver(from state: PublicState) -> PublicStateObserver {
                        PublicStateObserver(
                            count: state.count
                        )
                    }

                    @MainActor
                    public static func apply(_ snapshot: PublicState, to observer: PublicStateObserver) {
                        observer.count = snapshot.count
                    }

                    @MainActor
                    public static func applyRestore(from snapshot: PublicState, to current: inout PublicState) {
                        current.count = snapshot.count
                    }
                }
                """,
            macros: macros
        )
    }

    // MARK: Nested Type Qualification

    // The observer is a peer at *file* scope, so a property typed with one of the
    // struct's own nested types by its bare name generates an unresolvable
    // reference. Without these diagnostics the error surfaces inside the macro
    // expansion buffer instead of on the property the author wrote.

    func testUnqualifiedNestedTypeEmitsDiagnostic() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct PersistenceState: Equatable, Sendable {
                enum HydrationPhase: Sendable, Equatable {
                    case loading, ready
                }
                var phase: HydrationPhase = .loading
            }
            """,
            expandedSource: """
                struct PersistenceState: Equatable, Sendable {
                    enum HydrationPhase: Sendable, Equatable {
                        case loading, ready
                    }
                    var phase: HydrationPhase = .loading
                }

                @Observable
                @MainActor
                final class PersistenceStateObserver: @unchecked Sendable {
                    var phase: HydrationPhase

                    init(phase: HydrationPhase = .loading) {
                        self.phase = phase
                    }
                }

                extension PersistenceState: SwiduxObservable {
                    typealias Observer = PersistenceStateObserver

                    @MainActor
                    init(observer: PersistenceStateObserver) {
                        self.phase = observer.phase
                    }

                    @MainActor
                    static func makeObserver(from state: PersistenceState) -> PersistenceStateObserver {
                        PersistenceStateObserver(
                            phase: state.phase
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: PersistenceState, to observer: PersistenceStateObserver) {
                        observer.phase = snapshot.phase
                    }

                    @MainActor
                    static func applyRestore(from snapshot: PersistenceState, to current: inout PersistenceState) {
                        current.phase = snapshot.phase
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Nested type 'HydrationPhase' must be written with its qualified name 'PersistenceState.HydrationPhase'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 6,
                    column: 16
                )
            ],
            macros: macros
        )
    }

    func testQualifiedNestedTypeIsNotDiagnosed() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct PersistenceState: Equatable, Sendable {
                enum HydrationPhase: Sendable, Equatable {
                    case loading, ready
                }
                var phase: PersistenceState.HydrationPhase = .loading
            }
            """,
            expandedSource: """
                struct PersistenceState: Equatable, Sendable {
                    enum HydrationPhase: Sendable, Equatable {
                        case loading, ready
                    }
                    var phase: PersistenceState.HydrationPhase = .loading
                }

                @Observable
                @MainActor
                final class PersistenceStateObserver: @unchecked Sendable {
                    var phase: PersistenceState.HydrationPhase

                    init(phase: PersistenceState.HydrationPhase = .loading) {
                        self.phase = phase
                    }
                }

                extension PersistenceState: SwiduxObservable {
                    typealias Observer = PersistenceStateObserver

                    @MainActor
                    init(observer: PersistenceStateObserver) {
                        self.phase = observer.phase
                    }

                    @MainActor
                    static func makeObserver(from state: PersistenceState) -> PersistenceStateObserver {
                        PersistenceStateObserver(
                            phase: state.phase
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: PersistenceState, to observer: PersistenceStateObserver) {
                        observer.phase = snapshot.phase
                    }

                    @MainActor
                    static func applyRestore(from snapshot: PersistenceState, to current: inout PersistenceState) {
                        current.phase = snapshot.phase
                    }
                }
                """,
            macros: macros
        )
    }

    func testUnqualifiedNestedTypeInOptionalEmitsDiagnostic() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct OptionalPhaseState: Equatable, Sendable {
                enum HydrationPhase: Sendable, Equatable {
                    case loading, ready
                }
                var phase: HydrationPhase? = nil
            }
            """,
            expandedSource: """
                struct OptionalPhaseState: Equatable, Sendable {
                    enum HydrationPhase: Sendable, Equatable {
                        case loading, ready
                    }
                    var phase: HydrationPhase? = nil
                }

                @Observable
                @MainActor
                final class OptionalPhaseStateObserver: @unchecked Sendable {
                    var phase: HydrationPhase?

                    init(phase: HydrationPhase? = nil) {
                        self.phase = phase
                    }
                }

                extension OptionalPhaseState: SwiduxObservable {
                    typealias Observer = OptionalPhaseStateObserver

                    @MainActor
                    init(observer: OptionalPhaseStateObserver) {
                        self.phase = observer.phase
                    }

                    @MainActor
                    static func makeObserver(from state: OptionalPhaseState) -> OptionalPhaseStateObserver {
                        OptionalPhaseStateObserver(
                            phase: state.phase
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: OptionalPhaseState, to observer: OptionalPhaseStateObserver) {
                        observer.phase = snapshot.phase
                    }

                    @MainActor
                    static func applyRestore(from snapshot: OptionalPhaseState, to current: inout OptionalPhaseState) {
                        current.phase = snapshot.phase
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Nested type 'HydrationPhase' must be written with its qualified name 'OptionalPhaseState.HydrationPhase'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 6,
                    column: 16
                )
            ],
            macros: macros
        )
    }

    func testUnqualifiedNestedTypeInGenericArgumentsEmitsDiagnostic() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct GenericPhaseState: Equatable, Sendable {
                enum HydrationPhase: Sendable, Equatable {
                    case loading, ready
                }
                var boxed: Optional<HydrationPhase> = nil
                var phases: Set<HydrationPhase> = []
            }
            """,
            expandedSource: """
                struct GenericPhaseState: Equatable, Sendable {
                    enum HydrationPhase: Sendable, Equatable {
                        case loading, ready
                    }
                    var boxed: Optional<HydrationPhase> = nil
                    var phases: Set<HydrationPhase> = []
                }

                @Observable
                @MainActor
                final class GenericPhaseStateObserver: @unchecked Sendable {
                    var boxed: Optional<HydrationPhase>
                    var phases: Set<HydrationPhase>

                    init(boxed: Optional<HydrationPhase> = nil, phases: Set<HydrationPhase> = []) {
                        self.boxed = boxed
                        self.phases = phases
                    }
                }

                extension GenericPhaseState: SwiduxObservable {
                    typealias Observer = GenericPhaseStateObserver

                    @MainActor
                    init(observer: GenericPhaseStateObserver) {
                        self.boxed = observer.boxed
                        self.phases = observer.phases
                    }

                    @MainActor
                    static func makeObserver(from state: GenericPhaseState) -> GenericPhaseStateObserver {
                        GenericPhaseStateObserver(
                            boxed: state.boxed,
                            phases: state.phases
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: GenericPhaseState, to observer: GenericPhaseStateObserver) {
                        observer.boxed = snapshot.boxed
                        observer.phases = snapshot.phases
                    }

                    @MainActor
                    static func applyRestore(from snapshot: GenericPhaseState, to current: inout GenericPhaseState) {
                        current.boxed = snapshot.boxed
                        current.phases = snapshot.phases
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Nested type 'HydrationPhase' must be written with its qualified name 'GenericPhaseState.HydrationPhase'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 6,
                    column: 25
                ),
                DiagnosticSpec(
                    message:
                        "Nested type 'HydrationPhase' must be written with its qualified name 'GenericPhaseState.HydrationPhase'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 7,
                    column: 21
                ),
            ],
            macros: macros
        )
    }

    func testUnqualifiedNestedTypeInCollectionsEmitsDiagnostics() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct CollectionPhaseState: Equatable, Sendable {
                enum HydrationPhase: Sendable, Equatable {
                    case loading, ready
                }
                var phases: [HydrationPhase] = []
                var map: [HydrationPhase: HydrationPhase] = [:]
            }
            """,
            expandedSource: """
                struct CollectionPhaseState: Equatable, Sendable {
                    enum HydrationPhase: Sendable, Equatable {
                        case loading, ready
                    }
                    var phases: [HydrationPhase] = []
                    var map: [HydrationPhase: HydrationPhase] = [:]
                }

                @Observable
                @MainActor
                final class CollectionPhaseStateObserver: @unchecked Sendable {
                    var phases: [HydrationPhase]
                    var map: [HydrationPhase: HydrationPhase]

                    init(phases: [HydrationPhase] = [], map: [HydrationPhase: HydrationPhase] = [:]) {
                        self.phases = phases
                        self.map = map
                    }
                }

                extension CollectionPhaseState: SwiduxObservable {
                    typealias Observer = CollectionPhaseStateObserver

                    @MainActor
                    init(observer: CollectionPhaseStateObserver) {
                        self.phases = observer.phases
                        self.map = observer.map
                    }

                    @MainActor
                    static func makeObserver(from state: CollectionPhaseState) -> CollectionPhaseStateObserver {
                        CollectionPhaseStateObserver(
                            phases: state.phases,
                            map: state.map
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: CollectionPhaseState, to observer: CollectionPhaseStateObserver) {
                        observer.phases = snapshot.phases
                        observer.map = snapshot.map
                    }

                    @MainActor
                    static func applyRestore(from snapshot: CollectionPhaseState, to current: inout CollectionPhaseState) {
                        current.phases = snapshot.phases
                        current.map = snapshot.map
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Nested type 'HydrationPhase' must be written with its qualified name 'CollectionPhaseState.HydrationPhase'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 6,
                    column: 18
                ),
                DiagnosticSpec(
                    message:
                        "Nested type 'HydrationPhase' must be written with its qualified name 'CollectionPhaseState.HydrationPhase'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 7,
                    column: 15
                ),
                DiagnosticSpec(
                    message:
                        "Nested type 'HydrationPhase' must be written with its qualified name 'CollectionPhaseState.HydrationPhase'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 7,
                    column: 31
                ),
            ],
            macros: macros
        )
    }

    func testUnqualifiedNestedStructClassAndTypealiasAreDiagnosed() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct MixedNestedState: Equatable, Sendable {
                struct Config: Sendable, Equatable {
                    var limit: Int = 0
                }
                final class Handle: Sendable {
                    let token: Int = 0
                }
                typealias Count = Int
                var config: Config = .init()
                var handle: Handle? = nil
                var count: Count = 0
            }
            """,
            expandedSource: """
                struct MixedNestedState: Equatable, Sendable {
                    struct Config: Sendable, Equatable {
                        var limit: Int = 0
                    }
                    final class Handle: Sendable {
                        let token: Int = 0
                    }
                    typealias Count = Int
                    var config: Config = .init()
                    var handle: Handle? = nil
                    var count: Count = 0
                }

                @Observable
                @MainActor
                final class MixedNestedStateObserver: @unchecked Sendable {
                    var config: Config
                    var handle: Handle?
                    var count: Count

                    init(config: Config = .init(), handle: Handle? = nil, count: Count = 0) {
                        self.config = config
                        self.handle = handle
                        self.count = count
                    }
                }

                extension MixedNestedState: SwiduxObservable {
                    typealias Observer = MixedNestedStateObserver

                    @MainActor
                    init(observer: MixedNestedStateObserver) {
                        self.config = observer.config
                        self.handle = observer.handle
                        self.count = observer.count
                    }

                    @MainActor
                    static func makeObserver(from state: MixedNestedState) -> MixedNestedStateObserver {
                        MixedNestedStateObserver(
                            config: state.config,
                            handle: state.handle,
                            count: state.count
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: MixedNestedState, to observer: MixedNestedStateObserver) {
                        observer.config = snapshot.config
                        observer.handle = snapshot.handle
                        observer.count = snapshot.count
                    }

                    @MainActor
                    static func applyRestore(from snapshot: MixedNestedState, to current: inout MixedNestedState) {
                        current.config = snapshot.config
                        current.handle = snapshot.handle
                        current.count = snapshot.count
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Nested type 'Config' must be written with its qualified name 'MixedNestedState.Config'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 10,
                    column: 17
                ),
                DiagnosticSpec(
                    message:
                        "Nested type 'Handle' must be written with its qualified name 'MixedNestedState.Handle'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 11,
                    column: 17
                ),
                DiagnosticSpec(
                    message:
                        "Nested type 'Count' must be written with its qualified name 'MixedNestedState.Count'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 12,
                    column: 16
                ),
            ],
            macros: macros
        )
    }

    func testUnqualifiedNestedTypeAsMemberBaseEmitsDiagnostic() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct MemberBaseState: Equatable, Sendable {
                struct Wrapper: Sendable, Equatable {
                    struct Inner: Sendable, Equatable {
                        var limit: Int = 0
                    }
                }
                var value: Wrapper.Inner = .init()
            }
            """,
            expandedSource: """
                struct MemberBaseState: Equatable, Sendable {
                    struct Wrapper: Sendable, Equatable {
                        struct Inner: Sendable, Equatable {
                            var limit: Int = 0
                        }
                    }
                    var value: Wrapper.Inner = .init()
                }

                @Observable
                @MainActor
                final class MemberBaseStateObserver: @unchecked Sendable {
                    var value: Wrapper.Inner

                    init(value: Wrapper.Inner = .init()) {
                        self.value = value
                    }
                }

                extension MemberBaseState: SwiduxObservable {
                    typealias Observer = MemberBaseStateObserver

                    @MainActor
                    init(observer: MemberBaseStateObserver) {
                        self.value = observer.value
                    }

                    @MainActor
                    static func makeObserver(from state: MemberBaseState) -> MemberBaseStateObserver {
                        MemberBaseStateObserver(
                            value: state.value
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: MemberBaseState, to observer: MemberBaseStateObserver) {
                        observer.value = snapshot.value
                    }

                    @MainActor
                    static func applyRestore(from snapshot: MemberBaseState, to current: inout MemberBaseState) {
                        current.value = snapshot.value
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Nested type 'Wrapper' must be written with its qualified name 'MemberBaseState.Wrapper'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 8,
                    column: 16
                )
            ],
            macros: macros
        )
    }

    // A file-scope type of the same name is the *worst* case, not an excuse to stay
    // quiet: inside the struct body the nested type shadows it, so the property's
    // real type is the nested one while the peer observer silently binds the
    // file-scope one — a type mismatch even further from the cause.
    func testNestedTypeShadowingFileScopeTypeIsDiagnosed() throws {
        assertMacroExpansion(
            """
            enum Phase: Sendable, Equatable {
                case idle
            }

            @Swidux
            struct ShadowState: Equatable, Sendable {
                enum Phase: Sendable, Equatable {
                    case loading
                }
                var phase: Phase = .loading
            }
            """,
            expandedSource: """
                enum Phase: Sendable, Equatable {
                    case idle
                }
                struct ShadowState: Equatable, Sendable {
                    enum Phase: Sendable, Equatable {
                        case loading
                    }
                    var phase: Phase = .loading
                }

                @Observable
                @MainActor
                final class ShadowStateObserver: @unchecked Sendable {
                    var phase: Phase

                    init(phase: Phase = .loading) {
                        self.phase = phase
                    }
                }

                extension ShadowState: SwiduxObservable {
                    typealias Observer = ShadowStateObserver

                    @MainActor
                    init(observer: ShadowStateObserver) {
                        self.phase = observer.phase
                    }

                    @MainActor
                    static func makeObserver(from state: ShadowState) -> ShadowStateObserver {
                        ShadowStateObserver(
                            phase: state.phase
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: ShadowState, to observer: ShadowStateObserver) {
                        observer.phase = snapshot.phase
                    }

                    @MainActor
                    static func applyRestore(from snapshot: ShadowState, to current: inout ShadowState) {
                        current.phase = snapshot.phase
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Nested type 'Phase' must be written with its qualified name 'ShadowState.Phase'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 10,
                    column: 16
                )
            ],
            macros: macros
        )
    }

    // `@Slice` builds the observer's type as `<baseTypeName>Observer`, which is
    // equally unresolvable at file scope when the slice type is spelled bare.
    func testUnqualifiedNestedSliceTypeEmitsDiagnostic() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct SliceParentState: Equatable, Sendable {
                struct ChildState: Equatable, Sendable {
                    var count: Int = 0
                }
                @Slice var child: ChildState = .init()
            }
            """,
            expandedSource: """
                struct SliceParentState: Equatable, Sendable {
                    struct ChildState: Equatable, Sendable {
                        var count: Int = 0
                    }
                    var child: ChildState = .init()
                }

                @Observable
                @MainActor
                final class SliceParentStateObserver: @unchecked Sendable {
                    let child: ChildStateObserver

                    init(child: ChildStateObserver = ChildStateObserver()) {
                        self.child = child
                    }
                }

                extension SliceParentState: SwiduxObservable {
                    typealias Observer = SliceParentStateObserver

                    @MainActor
                    init(observer: SliceParentStateObserver) {
                        self.child = ChildState(observer: observer.child)
                    }

                    @MainActor
                    static func makeObserver(from state: SliceParentState) -> SliceParentStateObserver {
                        SliceParentStateObserver(
                            child: ChildState.makeObserver(from: state.child)
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: SliceParentState, to observer: SliceParentStateObserver) {
                        ChildState.apply(snapshot.child, to: observer.child)
                    }

                    @MainActor
                    static func applyRestore(from snapshot: SliceParentState, to current: inout SliceParentState) {
                        ChildState.applyRestore(from: snapshot.child, to: &current.child)
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Nested type 'ChildState' must be written with its qualified name 'SliceParentState.ChildState'; the generated observer class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 6,
                    column: 23
                )
            ],
            macros: macros
        )
    }

    // The diagnostic tracks what the classifier actually emits. A nested type used
    // only by a computed property never reaches the observer, so flagging it would
    // be a false positive.
    func testNestedTypeUsedOnlyByComputedPropertyIsNotDiagnosed() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct ComputedOnlyState: Equatable, Sendable {
                enum Phase: Sendable, Equatable {
                    case loading
                }
                var count: Int = 0
                var phase: Phase { .loading }
            }
            """,
            expandedSource: """
                struct ComputedOnlyState: Equatable, Sendable {
                    enum Phase: Sendable, Equatable {
                        case loading
                    }
                    var count: Int = 0
                    var phase: Phase { .loading }
                }

                @Observable
                @MainActor
                final class ComputedOnlyStateObserver: @unchecked Sendable {
                    var count: Int

                    init(count: Int = 0) {
                        self.count = count
                    }
                }

                extension ComputedOnlyState: SwiduxObservable {
                    typealias Observer = ComputedOnlyStateObserver

                    @MainActor
                    init(observer: ComputedOnlyStateObserver) {
                        self.count = observer.count
                    }

                    @MainActor
                    static func makeObserver(from state: ComputedOnlyState) -> ComputedOnlyStateObserver {
                        ComputedOnlyStateObserver(
                            count: state.count
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: ComputedOnlyState, to observer: ComputedOnlyStateObserver) {
                        observer.count = snapshot.count
                    }

                    @MainActor
                    static func applyRestore(from snapshot: ComputedOnlyState, to current: inout ComputedOnlyState) {
                        current.count = snapshot.count
                    }
                }
                """,
            macros: macros
        )
    }
}
#endif
