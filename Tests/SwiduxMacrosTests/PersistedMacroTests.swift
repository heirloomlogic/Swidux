import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

#if canImport(SwiduxMacros)
import SwiduxMacros
#endif

// MARK: - @Persisted

final class PersistedMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Persisted": PersistedMacro.self,
        "Relation": MarkerMacro.self,
        "ForeignKey": MarkerMacro.self,
        "Inline": MarkerMacro.self,
        "Ignored": MarkerMacro.self,
    ]

    func testSimpleEntity() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Counter: Identifiable, Equatable, Sendable {
                var id: UUID
                var name: String
                var count: Int
            }
            """,
            expandedSource: """
                struct Counter: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var name: String
                    var count: Int
                }

                @Model
                final class CounterModel: PersistableModel {
                    typealias Domain = Counter

                    var id: UUID
                    var name: String
                    var count: Int

                    init(from domain: Counter) {
                        self.id = domain.id
                        self.name = domain.name
                        self.count = domain.count
                    }

                    func toDomain() -> Counter {
                        Counter(
                            id: id,
                            name: name,
                            count: count
                        )
                    }

                    func update(from domain: Counter) {
                        self.name = domain.name
                        self.count = domain.count
                    }
                }

                extension Counter: PersistableEntity {
                    typealias Model = CounterModel
                }
                """,
            macros: macros
        )
    }

    func testInlineForeignKeyAndIgnored() throws {
        assertMacroExpansion(
            """
            @Persisted
            public struct Profile: Identifiable, Equatable, Sendable {
                public var id: UUID
                @Inline public var settings: Settings
                @ForeignKey public var ownerID: UUID
                @Ignored public var badge: String?
            }
            """,
            expandedSource: """
                public struct Profile: Identifiable, Equatable, Sendable {
                    public var id: UUID
                    public var settings: Settings
                    public var ownerID: UUID
                    public var badge: String?
                }

                @Model
                public final class ProfileModel: PersistableModel {
                    public typealias Domain = Profile

                    private static let swiduxInlineEncoder = JSONEncoder()
                    private static let swiduxInlineDecoder = JSONDecoder()
                    public var id: UUID
                    private var settingsData: Data
                    public var settings: Settings {
                        get {
                            do {
                                return try Self.swiduxInlineDecoder.decode(Settings.self, from: settingsData)
                            }
                            catch {
                                fatalError("Swidux @Inline: failed to decode settings: \\(error)")
                            }
                        }
                        set {
                            settingsData = (try? Self.swiduxInlineEncoder.encode(newValue)) ?? Data()
                        }
                    }
                    public var ownerID: UUID

                    public init(from domain: Profile) {
                        self.id = domain.id
                        self.settingsData = (try? Self.swiduxInlineEncoder.encode(domain.settings)) ?? Data()
                        self.ownerID = domain.ownerID
                    }

                    public func toDomain() -> Profile {
                        Profile(
                            id: id,
                            settings: settings,
                            ownerID: ownerID,
                            badge: nil
                        )
                    }

                    public func update(from domain: Profile) {
                        self.settings = domain.settings
                        self.ownerID = domain.ownerID
                    }
                }

                extension Profile: PersistableEntity {
                    public typealias Model = ProfileModel
                }
                """,
            macros: macros
        )
    }

    func testRelation() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Deck: Identifiable, Equatable, Sendable {
                var id: UUID
                var title: String
                @Relation(deleteRule: .cascade, inverse: \\CardModel.deck) var cards: [Card]
            }
            """,
            expandedSource: """
                struct Deck: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var title: String
                    var cards: [Card]
                }

                @Model
                final class DeckModel: PersistableModel {
                    typealias Domain = Deck

                    var id: UUID
                    var title: String
                    @Relationship(deleteRule: .cascade, inverse: \\CardModel.deck) var cards: [CardModel]

                    init(from domain: Deck) {
                        self.id = domain.id
                        self.title = domain.title
                        self.cards = domain.cards.map {
                            CardModel(from: $0)
                        }
                    }

                    func toDomain() -> Deck {
                        Deck(
                            id: id,
                            title: title,
                            cards: cards.map {
                                $0.toDomain()
                            }
                        )
                    }

                    func update(from domain: Deck) {
                        self.title = domain.title
                        self.cards = domain.cards.map {
                            CardModel(from: $0)
                        }
                    }
                }

                extension Deck: PersistableEntity {
                    typealias Model = DeckModel
                }
                """,
            macros: macros
        )
    }

    func testRelationToOne() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Pet: Identifiable, Equatable, Sendable {
                var id: UUID
                @Relation(deleteRule: .nullify) var owner: Person
            }
            """,
            expandedSource: """
                struct Pet: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var owner: Person
                }

                @Model
                final class PetModel: PersistableModel {
                    typealias Domain = Pet

                    var id: UUID
                    @Relationship(deleteRule: .nullify) var owner: PersonModel

                    init(from domain: Pet) {
                        self.id = domain.id
                        self.owner = PersonModel(from: domain.owner)
                    }

                    func toDomain() -> Pet {
                        Pet(
                            id: id,
                            owner: owner.toDomain()
                        )
                    }

                    func update(from domain: Pet) {
                        self.owner = PersonModel(from: domain.owner)
                    }
                }

                extension Pet: PersistableEntity {
                    typealias Model = PetModel
                }
                """,
            macros: macros
        )
    }

    func testOptionalInline() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Doc: Identifiable, Equatable, Sendable {
                var id: UUID
                @Inline var meta: Meta?
            }
            """,
            expandedSource: """
                struct Doc: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var meta: Meta?
                }

                @Model
                final class DocModel: PersistableModel {
                    typealias Domain = Doc

                    private static let swiduxInlineEncoder = JSONEncoder()
                    private static let swiduxInlineDecoder = JSONDecoder()
                    var id: UUID
                    private var metaData: Data
                    var meta: Meta? {
                        get {
                            (try? Self.swiduxInlineDecoder.decode(Meta?.self, from: metaData)) ?? nil
                        }
                        set {
                            metaData = (try? Self.swiduxInlineEncoder.encode(newValue)) ?? Data()
                        }
                    }

                    init(from domain: Doc) {
                        self.id = domain.id
                        self.metaData = (try? Self.swiduxInlineEncoder.encode(domain.meta)) ?? Data()
                    }

                    func toDomain() -> Doc {
                        Doc(
                            id: id,
                            meta: meta
                        )
                    }

                    func update(from domain: Doc) {
                        self.meta = domain.meta
                    }
                }

                extension Doc: PersistableEntity {
                    typealias Model = DocModel
                }
                """,
            macros: macros
        )
    }

    func testRejectsNonStruct() throws {
        assertMacroExpansion(
            """
            @Persisted
            enum Color {
                case red
            }
            """,
            expandedSource: """
                enum Color {
                    case red
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: "@Persisted can only be applied to structs", line: 1, column: 1)
            ],
            macros: macros
        )
    }

    func testIgnoredMustBeOptional() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Foo: Identifiable, Equatable, Sendable {
                var id: UUID
                @Ignored var tag: String
            }
            """,
            expandedSource: """
                struct Foo: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var tag: String
                }

                @Model
                final class FooModel: PersistableModel {
                    typealias Domain = Foo

                    var id: UUID

                    init(from domain: Foo) {
                        self.id = domain.id
                    }

                    func toDomain() -> Foo {
                        Foo(
                            id: id,
                            tag: nil
                        )
                    }

                    func update(from domain: Foo) {

                    }
                }

                extension Foo: PersistableEntity {
                    typealias Model = FooModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Ignored properties must be optional so they can be reconstructed as nil when loading from storage",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }
}
