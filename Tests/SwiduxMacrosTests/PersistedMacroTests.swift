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

                    var id: UUID = UUID()
                    var name: String = ""
                    var count: Int = 0

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

                    static func swiduxFetchDescriptor(id: UUID) -> FetchDescriptor<CounterModel> {
                        var descriptor = FetchDescriptor<CounterModel>(predicate: #Predicate {
                                $0.id == id
                            })
                        descriptor.fetchLimit = 1
                        return descriptor
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
                @Inline public var settings: Settings = Settings()
                @ForeignKey public var ownerID: UUID
                @Ignored public var badge: String?
            }
            """,
            expandedSource: """
                public struct Profile: Identifiable, Equatable, Sendable {
                    public var id: UUID
                    public var settings: Settings = Settings()
                    public var ownerID: UUID
                    public var badge: String?
                }

                @Model
                public final class ProfileModel: PersistableModel {
                    public typealias Domain = Profile

                    private static let swiduxInlineEncoder = JSONEncoder()
                    private static let swiduxInlineDecoder = JSONDecoder()
                    public var id: UUID = UUID()
                    private var settingsData: Data = Data()
                    public var settings: Settings {
                        get {
                            (try? Self.swiduxInlineDecoder.decode(Settings.self, from: settingsData)) ?? Settings()
                        }
                        set {
                            settingsData = (try? Self.swiduxInlineEncoder.encode(newValue)) ?? Data()
                        }
                    }
                    public var ownerID: UUID = UUID()

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

                    public static func swiduxFetchDescriptor(id: UUID) -> FetchDescriptor<ProfileModel> {
                        var descriptor = FetchDescriptor<ProfileModel>(predicate: #Predicate {
                                $0.id == id
                            })
                        descriptor.fetchLimit = 1
                        return descriptor
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

                    var id: UUID = UUID()
                    var title: String = ""
                    @Relationship(deleteRule: .cascade, inverse: \\CardModel.deck) var cards: [CardModel]? = nil

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
                            cards: (cards ?? []).map {
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

                    static func swiduxFetchDescriptor(id: UUID) -> FetchDescriptor<DeckModel> {
                        var descriptor = FetchDescriptor<DeckModel>(predicate: #Predicate {
                                $0.id == id
                            })
                        descriptor.fetchLimit = 1
                        return descriptor
                    }
                }

                extension Deck: PersistableEntity {
                    typealias Model = DeckModel
                }
                """,
            macros: macros
        )
    }

    func testRelationToOneNonOptionalIsDiagnosed() throws {
        // CloudKit forbids non-optional relationships: a non-optional to-one
        // `@Relation` is a build error. The model still expands (relationship
        // forced optional) so the error sits alongside otherwise-valid code.
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

                    var id: UUID = UUID()
                    @Relationship(deleteRule: .nullify) var owner: PersonModel? = nil

                    init(from domain: Pet) {
                        self.id = domain.id
                        self.owner = PersonModel(from: domain.owner)
                    }

                    func toDomain() -> Pet {
                        Pet(
                            id: id,
                            owner: owner!.toDomain()
                        )
                    }

                    func update(from domain: Pet) {
                        self.owner = PersonModel(from: domain.owner)
                    }

                    static func swiduxFetchDescriptor(id: UUID) -> FetchDescriptor<PetModel> {
                        var descriptor = FetchDescriptor<PetModel>(predicate: #Predicate {
                                $0.id == id
                            })
                        descriptor.fetchLimit = 1
                        return descriptor
                    }
                }

                extension Pet: PersistableEntity {
                    typealias Model = PetModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Relation to-one properties must be optional (T?) or to-many to be CloudKit-safe; CloudKit forbids non-optional relationships",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testRelationToOneOptional() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Pet: Identifiable, Equatable, Sendable {
                var id: UUID
                @Relation(deleteRule: .nullify) var owner: Person?
            }
            """,
            expandedSource: """
                struct Pet: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var owner: Person?
                }

                @Model
                final class PetModel: PersistableModel {
                    typealias Domain = Pet

                    var id: UUID = UUID()
                    @Relationship(deleteRule: .nullify) var owner: PersonModel? = nil

                    init(from domain: Pet) {
                        self.id = domain.id
                        self.owner = domain.owner.map {
                            PersonModel(from: $0)
                        }
                    }

                    func toDomain() -> Pet {
                        Pet(
                            id: id,
                            owner: owner.map {
                                $0.toDomain()
                            }
                        )
                    }

                    func update(from domain: Pet) {
                        self.owner = domain.owner.map {
                            PersonModel(from: $0)
                        }
                    }

                    static func swiduxFetchDescriptor(id: UUID) -> FetchDescriptor<PetModel> {
                        var descriptor = FetchDescriptor<PetModel>(predicate: #Predicate {
                                $0.id == id
                            })
                        descriptor.fetchLimit = 1
                        return descriptor
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
                    var id: UUID = UUID()
                    private var metaData: Data = Data()
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

                    static func swiduxFetchDescriptor(id: UUID) -> FetchDescriptor<DocModel> {
                        var descriptor = FetchDescriptor<DocModel>(predicate: #Predicate {
                                $0.id == id
                            })
                        descriptor.fetchLimit = 1
                        return descriptor
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

                    var id: UUID = UUID()

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

                    static func swiduxFetchDescriptor(id: UUID) -> FetchDescriptor<FooModel> {
                        var descriptor = FetchDescriptor<FooModel>(predicate: #Predicate {
                                $0.id == id
                            })
                        descriptor.fetchLimit = 1
                        return descriptor
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

    // MARK: - CloudKit-safe defaults

    func testUserDefaultPropagated() throws {
        // A default the user wrote on the domain property is propagated onto the
        // model verbatim, taking precedence over the canonical primitive default.
        assertMacroExpansion(
            """
            @Persisted
            struct Counter: Identifiable, Equatable, Sendable {
                var id: UUID
                var count: Int = 5
            }
            """,
            expandedSource: """
                struct Counter: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var count: Int = 5
                }

                @Model
                final class CounterModel: PersistableModel {
                    typealias Domain = Counter

                    var id: UUID = UUID()
                    var count: Int = 5

                    init(from domain: Counter) {
                        self.id = domain.id
                        self.count = domain.count
                    }

                    func toDomain() -> Counter {
                        Counter(
                            id: id,
                            count: count
                        )
                    }

                    func update(from domain: Counter) {
                        self.count = domain.count
                    }

                    static func swiduxFetchDescriptor(id: UUID) -> FetchDescriptor<CounterModel> {
                        var descriptor = FetchDescriptor<CounterModel>(predicate: #Predicate {
                                $0.id == id
                            })
                        descriptor.fetchLimit = 1
                        return descriptor
                    }
                }

                extension Counter: PersistableEntity {
                    typealias Model = CounterModel
                }
                """,
            macros: macros
        )
    }

    func testOptionalPrimitiveNeedsNoDefault() throws {
        // Optional attributes are CloudKit-safe with no default and no diagnostic.
        assertMacroExpansion(
            """
            @Persisted
            struct Person: Identifiable, Equatable, Sendable {
                var id: UUID
                var nickname: String?
            }
            """,
            expandedSource: """
                struct Person: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var nickname: String?
                }

                @Model
                final class PersonModel: PersistableModel {
                    typealias Domain = Person

                    var id: UUID = UUID()
                    var nickname: String?

                    init(from domain: Person) {
                        self.id = domain.id
                        self.nickname = domain.nickname
                    }

                    func toDomain() -> Person {
                        Person(
                            id: id,
                            nickname: nickname
                        )
                    }

                    func update(from domain: Person) {
                        self.nickname = domain.nickname
                    }

                    static func swiduxFetchDescriptor(id: UUID) -> FetchDescriptor<PersonModel> {
                        var descriptor = FetchDescriptor<PersonModel>(predicate: #Predicate {
                                $0.id == id
                            })
                        descriptor.fetchLimit = 1
                        return descriptor
                    }
                }

                extension Person: PersistableEntity {
                    typealias Model = PersonModel
                }
                """,
            macros: macros
        )
    }

    func testNonPrimitiveRequiresDefault() throws {
        // A non-optional, non-primitive mirrored property with no user default
        // and no @Inline cannot be made CloudKit-safe: the macro diagnoses it.
        assertMacroExpansion(
            """
            @Persisted
            struct Task: Identifiable, Equatable, Sendable {
                var id: UUID
                var status: Status
            }
            """,
            expandedSource: """
                struct Task: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var status: Status
                }

                @Model
                final class TaskModel: PersistableModel {
                    typealias Domain = Task

                    var id: UUID = UUID()
                    var status: Status

                    init(from domain: Task) {
                        self.id = domain.id
                        self.status = domain.status
                    }

                    func toDomain() -> Task {
                        Task(
                            id: id,
                            status: status
                        )
                    }

                    func update(from domain: Task) {
                        self.status = domain.status
                    }

                    static func swiduxFetchDescriptor(id: UUID) -> FetchDescriptor<TaskModel> {
                        var descriptor = FetchDescriptor<TaskModel>(predicate: #Predicate {
                                $0.id == id
                            })
                        descriptor.fetchLimit = 1
                        return descriptor
                    }
                }

                extension Task: PersistableEntity {
                    typealias Model = TaskModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Persisted properties of a non-primitive type must provide a default value (= …), be optional, or be marked @Inline to be CloudKit-safe",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testNonOptionalInlineRequiresDefault() throws {
        // A non-optional @Inline blob is backed by `Data()`, which is never
        // decodable; without a domain default the getter cannot recover.
        assertMacroExpansion(
            """
            @Persisted
            struct Profile: Identifiable, Equatable, Sendable {
                var id: UUID
                @Inline var settings: Settings
            }
            """,
            expandedSource: """
                struct Profile: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var settings: Settings
                }

                @Model
                final class ProfileModel: PersistableModel {
                    typealias Domain = Profile

                    private static let swiduxInlineEncoder = JSONEncoder()
                    private static let swiduxInlineDecoder = JSONDecoder()
                    var id: UUID = UUID()
                    private var settingsData: Data = Data()
                    var settings: Settings {
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

                    init(from domain: Profile) {
                        self.id = domain.id
                        self.settingsData = (try? Self.swiduxInlineEncoder.encode(domain.settings)) ?? Data()
                    }

                    func toDomain() -> Profile {
                        Profile(
                            id: id,
                            settings: settings
                        )
                    }

                    func update(from domain: Profile) {
                        self.settings = domain.settings
                    }

                    static func swiduxFetchDescriptor(id: UUID) -> FetchDescriptor<ProfileModel> {
                        var descriptor = FetchDescriptor<ProfileModel>(predicate: #Predicate {
                                $0.id == id
                            })
                        descriptor.fetchLimit = 1
                        return descriptor
                    }
                }

                extension Profile: PersistableEntity {
                    typealias Model = ProfileModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Non-optional @Inline properties must provide a default value (= …) or be optional, so a missing or undecodable blob can be recovered instead of crashing",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }
}
