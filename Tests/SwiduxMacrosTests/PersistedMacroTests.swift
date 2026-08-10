import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

// Macro implementations build for the host (macOS) only; when this test
// bundle compiles for another destination (the iOS-simulator CI job), the
// whole file must drop out, not just the import.
#if canImport(SwiduxMacros)
import SwiduxMacros

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

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
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

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<CounterModel> {
                        FetchDescriptor<CounterModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<CounterModel> {
                        FetchDescriptor<CounterModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
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
                    @Attribute(.preserveValueOnDeletion) public var id: UUID = UUID()
                    private var settingsData: Data = Data()
                    public var settings: Settings {
                        get {
                            SwiduxInlineCodec.decode(Settings.self, from: settingsData, decoder: \
                Self.swiduxInlineDecoder, model: "ProfileModel", property: "settings") ?? Settings()
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

                    public static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<ProfileModel> {
                        FetchDescriptor<ProfileModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    public static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<ProfileModel> {
                        FetchDescriptor<ProfileModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
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

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
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

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<DeckModel> {
                        FetchDescriptor<DeckModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<DeckModel> {
                        FetchDescriptor<DeckModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
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

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
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

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<PetModel> {
                        FetchDescriptor<PetModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<PetModel> {
                        FetchDescriptor<PetModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
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

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
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

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<PetModel> {
                        FetchDescriptor<PetModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<PetModel> {
                        FetchDescriptor<PetModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
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
                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
                    private var metaData: Data = Data()
                    var meta: Meta? {
                        get {
                            SwiduxInlineCodec.decode(Meta?.self, from: metaData, decoder: Self.swiduxInlineDecoder, \
                model: "DocModel", property: "meta") ?? nil
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

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<DocModel> {
                        FetchDescriptor<DocModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<DocModel> {
                        FetchDescriptor<DocModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
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

    func testInferredTypeIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Note: Identifiable, Equatable, Sendable {
                var id: UUID
                let pinned = false
            }
            """,
            expandedSource: """
                struct Note: Identifiable, Equatable, Sendable {
                    var id: UUID
                    let pinned = false
                }

                @Model
                final class NoteModel: PersistableModel {
                    typealias Domain = Note

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()

                    init(from domain: Note) {
                        self.id = domain.id
                    }

                    func toDomain() -> Note {
                        Note(
                            id: id
                        )
                    }

                    func update(from domain: Note) {

                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<NoteModel> {
                        FetchDescriptor<NoteModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<NoteModel> {
                        FetchDescriptor<NoteModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Note: PersistableEntity {
                    typealias Model = NoteModel
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

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()

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

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<FooModel> {
                        FetchDescriptor<FooModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<FooModel> {
                        FetchDescriptor<FooModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
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

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
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

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<CounterModel> {
                        FetchDescriptor<CounterModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<CounterModel> {
                        FetchDescriptor<CounterModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
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

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
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

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<PersonModel> {
                        FetchDescriptor<PersonModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<PersonModel> {
                        FetchDescriptor<PersonModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
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

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
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

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<TaskModel> {
                        FetchDescriptor<TaskModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<TaskModel> {
                        FetchDescriptor<TaskModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
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
                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
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

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<ProfileModel> {
                        FetchDescriptor<ProfileModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<ProfileModel> {
                        FetchDescriptor<ProfileModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
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

    // MARK: - Identity column

    // Only `id` is preserved on deletion, and only `id`. A tombstone outlives the
    // row, so every column listed here is data that deletion doesn't delete —
    // meanwhile, without the identity there is nothing to tell a peer device
    // *which* entity went away. Declaration order is the author's, so the
    // attribute has to follow the property rather than a fixed position.

    func testIdCarriesPreserveValueOnDeletionWhereverItIsDeclared() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Tag: Identifiable, Equatable, Sendable {
                var label: String
                var id: UUID
            }
            """,
            expandedSource: """
                struct Tag: Identifiable, Equatable, Sendable {
                    var label: String
                    var id: UUID
                }

                @Model
                final class TagModel: PersistableModel {
                    typealias Domain = Tag

                    var label: String = ""
                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()

                    init(from domain: Tag) {
                        self.label = domain.label
                        self.id = domain.id
                    }

                    func toDomain() -> Tag {
                        Tag(
                            label: label,
                            id: id
                        )
                    }

                    func update(from domain: Tag) {
                        self.label = domain.label
                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<TagModel> {
                        FetchDescriptor<TagModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<TagModel> {
                        FetchDescriptor<TagModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Tag: PersistableEntity {
                    typealias Model = TagModel
                }
                """,
            macros: macros
        )
    }

    // MARK: Nested Type Qualification

    // The `@Model` shadow class is a peer at *file* scope, so a property typed with
    // one of the domain struct's own nested types by its bare name generates an
    // unresolvable reference — the same failure mode `@Swidux` has with its observer.

    func testUnqualifiedNestedMirrorTypeIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Entry: Identifiable, Equatable, Sendable {
                enum Kind: Codable, Sendable, Equatable {
                    case note
                }
                var id: UUID
                var kind: Kind = .note
            }
            """,
            expandedSource: """
                struct Entry: Identifiable, Equatable, Sendable {
                    enum Kind: Codable, Sendable, Equatable {
                        case note
                    }
                    var id: UUID
                    var kind: Kind = .note
                }

                @Model
                final class EntryModel: PersistableModel {
                    typealias Domain = Entry

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
                    var kind: Kind = .note

                    init(from domain: Entry) {
                        self.id = domain.id
                        self.kind = domain.kind
                    }

                    func toDomain() -> Entry {
                        Entry(
                            id: id,
                            kind: kind
                        )
                    }

                    func update(from domain: Entry) {
                        self.kind = domain.kind
                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<EntryModel> {
                        FetchDescriptor<EntryModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<EntryModel> {
                        FetchDescriptor<EntryModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Entry: PersistableEntity {
                    typealias Model = EntryModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Nested type 'Kind' must be written with its qualified name 'Entry.Kind'; the generated model class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 7,
                    column: 15
                )
            ],
            macros: macros
        )
    }

    func testQualifiedNestedTypeIsNotDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Entry: Identifiable, Equatable, Sendable {
                enum Kind: Codable, Sendable, Equatable {
                    case note
                }
                var id: UUID
                var kind: Entry.Kind = .note
            }
            """,
            expandedSource: """
                struct Entry: Identifiable, Equatable, Sendable {
                    enum Kind: Codable, Sendable, Equatable {
                        case note
                    }
                    var id: UUID
                    var kind: Entry.Kind = .note
                }

                @Model
                final class EntryModel: PersistableModel {
                    typealias Domain = Entry

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
                    var kind: Entry.Kind = .note

                    init(from domain: Entry) {
                        self.id = domain.id
                        self.kind = domain.kind
                    }

                    func toDomain() -> Entry {
                        Entry(
                            id: id,
                            kind: kind
                        )
                    }

                    func update(from domain: Entry) {
                        self.kind = domain.kind
                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<EntryModel> {
                        FetchDescriptor<EntryModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<EntryModel> {
                        FetchDescriptor<EntryModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Entry: PersistableEntity {
                    typealias Model = EntryModel
                }
                """,
            macros: macros
        )
    }

    func testUnqualifiedNestedInlineTypeIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Profile: Identifiable, Equatable, Sendable {
                struct Settings: Codable, Sendable, Equatable {
                    var theme: Int = 0
                }
                var id: UUID
                @Inline var settings: Settings = Settings()
            }
            """,
            expandedSource: """
                struct Profile: Identifiable, Equatable, Sendable {
                    struct Settings: Codable, Sendable, Equatable {
                        var theme: Int = 0
                    }
                    var id: UUID
                    var settings: Settings = Settings()
                }

                @Model
                final class ProfileModel: PersistableModel {
                    typealias Domain = Profile

                    private static let swiduxInlineEncoder = JSONEncoder()
                    private static let swiduxInlineDecoder = JSONDecoder()
                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
                    private var settingsData: Data = Data()
                    var settings: Settings {
                        get {
                            SwiduxInlineCodec.decode(Settings.self, from: settingsData, decoder: \
                Self.swiduxInlineDecoder, model: "ProfileModel", property: "settings") ?? Settings()
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

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<ProfileModel> {
                        FetchDescriptor<ProfileModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<ProfileModel> {
                        FetchDescriptor<ProfileModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Profile: PersistableEntity {
                    typealias Model = ProfileModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Nested type 'Settings' must be written with its qualified name 'Profile.Settings'; the generated model class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 7,
                    column: 27
                )
            ],
            macros: macros
        )
    }

    // A `@Relation` emits `<element>Model`, which is itself a file-scope peer, so a
    // bare nested element type is unresolvable for exactly the same reason.
    func testUnqualifiedNestedRelationTypeIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Deck: Identifiable, Equatable, Sendable {
                struct Card: Identifiable, Equatable, Sendable {
                    var id: UUID
                }
                var id: UUID
                @Relation var cards: [Card] = []
            }
            """,
            expandedSource: """
                struct Deck: Identifiable, Equatable, Sendable {
                    struct Card: Identifiable, Equatable, Sendable {
                        var id: UUID
                    }
                    var id: UUID
                    var cards: [Card] = []
                }

                @Model
                final class DeckModel: PersistableModel {
                    typealias Domain = Deck

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
                    @Relationship var cards: [CardModel]? = nil

                    init(from domain: Deck) {
                        self.id = domain.id
                        self.cards = domain.cards.map {
                            CardModel(from: $0)
                        }
                    }

                    func toDomain() -> Deck {
                        Deck(
                            id: id,
                            cards: (cards ?? []).map {
                                $0.toDomain()
                            }
                        )
                    }

                    func update(from domain: Deck) {
                        self.cards = domain.cards.map {
                            CardModel(from: $0)
                        }
                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<DeckModel> {
                        FetchDescriptor<DeckModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<DeckModel> {
                        FetchDescriptor<DeckModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Deck: PersistableEntity {
                    typealias Model = DeckModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Nested type 'Card' must be written with its qualified name 'Deck.Card'; the generated model class is emitted as a peer at file scope, where the bare name doesn't resolve",
                    line: 7,
                    column: 27
                )
            ],
            macros: macros
        )
    }

    // `@Ignored` has no column and no type reference on the model, so its type never
    // reaches file scope — flagging it would be a false positive.
    func testUnqualifiedNestedIgnoredTypeIsNotDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Badge: Identifiable, Equatable, Sendable {
                struct Detail: Sendable, Equatable {
                    var note: String = ""
                }
                var id: UUID
                @Ignored var detail: Detail? = nil
            }
            """,
            expandedSource: """
                struct Badge: Identifiable, Equatable, Sendable {
                    struct Detail: Sendable, Equatable {
                        var note: String = ""
                    }
                    var id: UUID
                    var detail: Detail? = nil
                }

                @Model
                final class BadgeModel: PersistableModel {
                    typealias Domain = Badge

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()

                    init(from domain: Badge) {
                        self.id = domain.id
                    }

                    func toDomain() -> Badge {
                        Badge(
                            id: id,
                            detail: nil
                        )
                    }

                    func update(from domain: Badge) {

                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<BadgeModel> {
                        FetchDescriptor<BadgeModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<BadgeModel> {
                        FetchDescriptor<BadgeModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Badge: PersistableEntity {
                    typealias Model = BadgeModel
                }
                """,
            macros: macros
        )
    }
}
#endif
