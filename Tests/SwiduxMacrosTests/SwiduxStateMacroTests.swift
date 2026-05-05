import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

#if canImport(SwiduxMacros)
import SwiduxMacros
#endif

// MARK: - @SwiduxNested Marker

final class SwiduxNestedMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "SwiduxNested": SwiduxNestedMacro.self
    ]

    func testNestedGeneratesNothing() throws {
        assertMacroExpansion(
            """
            struct Parent {
                @SwiduxNested var ui: UIState = .init()
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

// MARK: - @SwiduxState

final class SwiduxStateMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "SwiduxState": SwiduxStateMacro.self,
        "SwiduxNested": SwiduxNestedMacro.self,
    ]

    // MARK: Leaf Properties

    func testSingleLeafProperty() throws {
        assertMacroExpansion(
            """
            @SwiduxState
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
            @SwiduxState
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
            @SwiduxState
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
            @SwiduxState
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
            @SwiduxState
            struct ParentState: Equatable, Sendable {
                var count: Int = 0
                @SwiduxNested var child: ChildState = .init()
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
            @SwiduxState
            struct AppState: Equatable, Sendable {
                var counters: EntityStore<Counter> = .init()
                @SwiduxNested var ui: UIState = .init()
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
            @SwiduxState
            class BadClass {}
            """,
            expandedSource: """
                class BadClass {}
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@SwiduxState can only be applied to structs",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    // MARK: Edge Cases

    func testPropertyWithNoDefault() throws {
        assertMacroExpansion(
            """
            @SwiduxState
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
            @SwiduxState
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
                    var count: Int

                    init(count: Int = 0) {
                        self.count = count
                    }
                }

                extension PublicState: SwiduxObservable {
                    typealias Observer = PublicStateObserver

                    @MainActor
                    init(observer: PublicStateObserver) {
                        self.count = observer.count
                    }

                    @MainActor
                    static func makeObserver(from state: PublicState) -> PublicStateObserver {
                        PublicStateObserver(
                            count: state.count
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: PublicState, to observer: PublicStateObserver) {
                        observer.count = snapshot.count
                    }

                    @MainActor
                    static func applyRestore(from snapshot: PublicState, to current: inout PublicState) {
                        current.count = snapshot.count
                    }
                }
                """,
            macros: macros
        )
    }
}
