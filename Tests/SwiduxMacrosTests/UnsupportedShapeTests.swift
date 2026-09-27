import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

// Macro implementations build for the host (macOS) only; when this test
// bundle compiles for another destination (the iOS-simulator CI job), the
// whole file must drop out, not just the import.
#if canImport(SwiduxMacros)
import SwiduxMacros

// MARK: - Shapes the macros can't carry

/// Declarations each macro once accepted and then either dropped silently (the
/// value reset on every pack, or never persisted) or expanded into code that
/// failed only inside the expansion buffer. Each must now be a pointed error on
/// the declaration the author wrote.
final class UnsupportedShapeTests: XCTestCase {
    let swidux: [String: Macro.Type] = [
        "Swidux": SwiduxMacro.self,
        "Slice": SliceMacro.self,
    ]

    let persisted: [String: Macro.Type] = [
        "Persisted": PersistedMacro.self,
        "Relation": MarkerMacro.self,
        "ForeignKey": MarkerMacro.self,
        "Inline": MarkerMacro.self,
        "Ignored": MarkerMacro.self,
    ]

    // MARK: @Swidux

    func testSwiduxStoredPropertyInIfConfigIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct FlagState: Equatable, Sendable {
                var count: Int = 0
                #if DEBUG
                var overlay: Bool = false
                static var debugOnly: Int = 0
                var computed: Int { 1 }
                #endif
            }
            """,
            expandedSource: """
                struct FlagState: Equatable, Sendable {
                    var count: Int = 0
                    #if DEBUG
                    var overlay: Bool = false
                    static var debugOnly: Int = 0
                    var computed: Int { 1 }
                    #endif
                }

                @Observable
                @MainActor
                final class FlagStateObserver: @unchecked Sendable {
                    var count: Int

                    init(count: Int = 0) {
                        self.count = count
                    }
                }

                extension FlagState: SwiduxObservable {
                    typealias Observer = FlagStateObserver

                    @MainActor
                    init(observer: FlagStateObserver) {
                        self.count = observer.count
                    }

                    @MainActor
                    static func makeObserver(from state: FlagState) -> FlagStateObserver {
                        FlagStateObserver(
                            count: state.count
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: FlagState, to observer: FlagStateObserver) {
                        observer.count = snapshot.count
                    }

                    @MainActor
                    static func applyRestore(from snapshot: FlagState, to current: inout FlagState) {
                        SwiduxRestore.restore(&current.count, from: snapshot.count)
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.ifConfig, line: 5, column: 5)
            ],
            macros: swidux
        )
    }

    func testSwiduxTuplePatternIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct PairState: Equatable, Sendable {
                var count: Int = 0
                var (a, b): (Int, Int) = (0, 0)
            }
            """,
            expandedSource: """
                struct PairState: Equatable, Sendable {
                    var count: Int = 0
                    var (a, b): (Int, Int) = (0, 0)
                }

                @Observable
                @MainActor
                final class PairStateObserver: @unchecked Sendable {
                    var count: Int

                    init(count: Int = 0) {
                        self.count = count
                    }
                }

                extension PairState: SwiduxObservable {
                    typealias Observer = PairStateObserver

                    @MainActor
                    init(observer: PairStateObserver) {
                        self.count = observer.count
                    }

                    @MainActor
                    static func makeObserver(from state: PairState) -> PairStateObserver {
                        PairStateObserver(
                            count: state.count
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: PairState, to observer: PairStateObserver) {
                        observer.count = snapshot.count
                    }

                    @MainActor
                    static func applyRestore(from snapshot: PairState, to current: inout PairState) {
                        SwiduxRestore.restore(&current.count, from: snapshot.count)
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.tuple, line: 4, column: 9)
            ],
            macros: swidux
        )
    }

    func testSwiduxLazyPropertyIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct LazyState: Equatable, Sendable {
                var count: Int = 0
                lazy var cache: [Int] = []
            }
            """,
            expandedSource: """
                struct LazyState: Equatable, Sendable {
                    var count: Int = 0
                    lazy var cache: [Int] = []
                }

                @Observable
                @MainActor
                final class LazyStateObserver: @unchecked Sendable {
                    var count: Int

                    init(count: Int = 0) {
                        self.count = count
                    }
                }

                extension LazyState: SwiduxObservable {
                    typealias Observer = LazyStateObserver

                    @MainActor
                    init(observer: LazyStateObserver) {
                        self.count = observer.count
                    }

                    @MainActor
                    static func makeObserver(from state: LazyState) -> LazyStateObserver {
                        LazyStateObserver(
                            count: state.count
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: LazyState, to observer: LazyStateObserver) {
                        observer.count = snapshot.count
                    }

                    @MainActor
                    static func applyRestore(from snapshot: LazyState, to current: inout LazyState) {
                        SwiduxRestore.restore(&current.count, from: snapshot.count)
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.lazy, line: 4, column: 5)
            ],
            macros: swidux
        )
    }

    func testSwiduxGenericStructIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct BoxState<Value: Equatable & Sendable>: Equatable, Sendable {
                var value: Value
            }
            """,
            expandedSource: """
                struct BoxState<Value: Equatable & Sendable>: Equatable, Sendable {
                    var value: Value
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.genericSwidux, line: 2, column: 16)
            ],
            macros: swidux
        )
    }

    func testSwiduxPrivateStructIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Swidux
            fileprivate struct HiddenState: Equatable, Sendable {
                var count: Int = 0
            }
            """,
            expandedSource: """
                fileprivate struct HiddenState: Equatable, Sendable {
                    var count: Int = 0
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.restrictedAccess("Swidux"), line: 2, column: 1)
            ],
            macros: swidux
        )
    }

    func testSliceOnUnnamedTypeIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct HostState: Equatable, Sendable {
                @Slice var child: ChildState? = nil
            }
            """,
            expandedSource: """
                struct HostState: Equatable, Sendable {
                    var child: ChildState? = nil
                }

                @Observable
                @MainActor
                final class HostStateObserver: @unchecked Sendable {
                    var child: ChildState?

                    init(child: ChildState? = nil) {
                        self.child = child
                    }
                }

                extension HostState: SwiduxObservable {
                    typealias Observer = HostStateObserver

                    @MainActor
                    init(observer: HostStateObserver) {
                        self.child = observer.child
                    }

                    @MainActor
                    static func makeObserver(from state: HostState) -> HostStateObserver {
                        HostStateObserver(
                            child: state.child
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: HostState, to observer: HostStateObserver) {
                        observer.child = snapshot.child
                    }

                    @MainActor
                    static func applyRestore(from snapshot: HostState, to current: inout HostState) {
                        SwiduxRestore.restore(&current.child, from: snapshot.child)
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.sliceType, line: 3, column: 23)
            ],
            macros: swidux
        )
    }

    // A default is copied into the observer's initializer, outside the struct:
    // a bare nested name doesn't resolve there, and `Self` names the observer.
    func testNestedNameAndSelfInDefaultAreDiagnosed() throws {
        assertMacroExpansion(
            """
            @Swidux
            struct PhaseState: Equatable, Sendable {
                enum Phase: Equatable, Sendable { case idle }
                static let defaultLimit: Int = 3
                var phase: PhaseState.Phase = Phase.idle
                var limit: Int = Self.defaultLimit
                var other: PhaseState.Phase = PhaseState.Phase.idle
            }
            """,
            expandedSource: """
                struct PhaseState: Equatable, Sendable {
                    enum Phase: Equatable, Sendable { case idle 
                }
                    static let defaultLimit: Int = 3
                    var phase: PhaseState.Phase = Phase.idle
                    var limit: Int = Self.defaultLimit
                    var other: PhaseState.Phase = PhaseState.Phase.idle
                }

                @Observable
                @MainActor
                final class PhaseStateObserver: @unchecked Sendable {
                    var phase: PhaseState.Phase
                    var limit: Int
                    var other: PhaseState.Phase

                    init(phase: PhaseState.Phase = Phase.idle, limit: Int = Self.defaultLimit, \
                other: PhaseState.Phase = PhaseState.Phase.idle) {
                        self.phase = phase
                        self.limit = limit
                        self.other = other
                    }
                }

                extension PhaseState: SwiduxObservable {
                    typealias Observer = PhaseStateObserver

                    @MainActor
                    init(observer: PhaseStateObserver) {
                        self.phase = observer.phase
                        self.limit = observer.limit
                        self.other = observer.other
                    }

                    @MainActor
                    static func makeObserver(from state: PhaseState) -> PhaseStateObserver {
                        PhaseStateObserver(
                            phase: state.phase,
                            limit: state.limit,
                            other: state.other
                        )
                    }

                    @MainActor
                    static func apply(_ snapshot: PhaseState, to observer: PhaseStateObserver) {
                        observer.phase = snapshot.phase
                        observer.limit = snapshot.limit
                        observer.other = snapshot.other
                    }

                    @MainActor
                    static func applyRestore(from snapshot: PhaseState, to current: inout PhaseState) {
                        SwiduxRestore.restore(&current.phase, from: snapshot.phase)
                        SwiduxRestore.restore(&current.limit, from: snapshot.limit)
                        SwiduxRestore.restore(&current.other, from: snapshot.other)
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: Message.nested("Phase", in: "PhaseState", "observer class"), line: 5, column: 35),
                DiagnosticSpec(message: Message.selfDefault("PhaseState", "observer class"), line: 6, column: 22),
            ],
            macros: swidux
        )
    }

    // MARK: @Persisted

    func testPersistedStoredPropertyInIfConfigIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Pin: Identifiable, Equatable, Sendable {
                var id: UUID
                #if os(iOS)
                var pinned: Bool = false
                #endif
            }
            """,
            expandedSource: """
                struct Pin: Identifiable, Equatable, Sendable {
                    var id: UUID
                    #if os(iOS)
                    var pinned: Bool = false
                    #endif
                }

                @Model
                final class PinModel: PersistableModel {
                    typealias Domain = Pin

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()

                    init(from domain: Pin) throws {
                        self.id = domain.id
                    }

                    func toDomain() throws -> Pin {
                        Pin(
                            id: id
                        )
                    }

                    func update(from domain: Pin) throws {

                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<PinModel> {
                        FetchDescriptor<PinModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<PinModel> {
                        FetchDescriptor<PinModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Pin: PersistableEntity {
                    typealias Model = PinModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.ifConfig, line: 5, column: 5)
            ],
            macros: persisted
        )
    }

    // An optional `@Ignored` has no column and loads as `nil` either way, so a
    // surrounding `#if` changes nothing; computed and static members under `#if`
    // are never generated from. Only a non-optional `@Ignored` is still an error,
    // the same one it gets unconditionally.
    func testPersistedIfConfigAllowsSkippedMembers() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Memo: Identifiable, Equatable, Sendable {
                var id: UUID
                #if DEBUG
                @Ignored var debugTrace: String? = nil
                @Ignored var badge: String
                var shouted: String { "" }
                static var count: Int = 0
                #endif
            }
            """,
            expandedSource: """
                struct Memo: Identifiable, Equatable, Sendable {
                    var id: UUID
                    #if DEBUG
                    var debugTrace: String? = nil
                    var badge: String
                    var shouted: String { "" }
                    static var count: Int = 0
                    #endif
                }

                @Model
                final class MemoModel: PersistableModel {
                    typealias Domain = Memo

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()

                    init(from domain: Memo) throws {
                        self.id = domain.id
                    }

                    func toDomain() throws -> Memo {
                        Memo(
                            id: id
                        )
                    }

                    func update(from domain: Memo) throws {

                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<MemoModel> {
                        FetchDescriptor<MemoModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<MemoModel> {
                        FetchDescriptor<MemoModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Memo: PersistableEntity {
                    typealias Model = MemoModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.ignoredOptional, line: 6, column: 18)
            ],
            macros: persisted
        )
    }

    func testPersistedInitializedLetIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Tagged: Identifiable, Equatable, Sendable {
                var id: UUID
                let kind: String = "note"
            }
            """,
            expandedSource: """
                struct Tagged: Identifiable, Equatable, Sendable {
                    var id: UUID
                    let kind: String = "note"
                }

                @Model
                final class TaggedModel: PersistableModel {
                    typealias Domain = Tagged

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()

                    init(from domain: Tagged) throws {
                        self.id = domain.id
                    }

                    func toDomain() throws -> Tagged {
                        Tagged(
                            id: id
                        )
                    }

                    func update(from domain: Tagged) throws {

                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<TaggedModel> {
                        FetchDescriptor<TaggedModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<TaggedModel> {
                        FetchDescriptor<TaggedModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Tagged: PersistableEntity {
                    typealias Model = TaggedModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.initializedLet, line: 4, column: 5)
            ],
            macros: persisted
        )
    }

    func testPersistedPrivatePropertyIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Secret: Identifiable, Equatable, Sendable {
                var id: UUID
                private var token: String = ""
                private(set) var visible: String = ""
            }
            """,
            expandedSource: """
                struct Secret: Identifiable, Equatable, Sendable {
                    var id: UUID
                    private var token: String = ""
                    private(set) var visible: String = ""
                }

                @Model
                final class SecretModel: PersistableModel {
                    typealias Domain = Secret

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
                    fileprivate var token: String = ""
                    var visible: String = ""

                    init(from domain: Secret) throws {
                        self.id = domain.id
                        self.token = domain.token
                        self.visible = domain.visible
                    }

                    func toDomain() throws -> Secret {
                        Secret(
                            id: id,
                            token: token,
                            visible: visible
                        )
                    }

                    func update(from domain: Secret) throws {
                        self.token = domain.token
                        self.visible = domain.visible
                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<SecretModel> {
                        FetchDescriptor<SecretModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<SecretModel> {
                        FetchDescriptor<SecretModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Secret: PersistableEntity {
                    typealias Model = SecretModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.privateProperty, line: 4, column: 17)
            ],
            macros: persisted
        )
    }

    func testPersistedGenericAndFileprivateStructsAreDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            fileprivate struct Wrapper<Value: Codable>: Identifiable, Equatable, Sendable {
                var id: UUID
            }
            """,
            expandedSource: """
                fileprivate struct Wrapper<Value: Codable>: Identifiable, Equatable, Sendable {
                    var id: UUID
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.genericPersisted, line: 2, column: 27),
                DiagnosticSpec(message: Message.restrictedAccess("Persisted"), line: 2, column: 1),
            ],
            macros: persisted
        )
    }

    // `Optional<T>` is as optional as `T?`: no default is required, `@Ignored`
    // accepts it, and a to-one `@Relation` maps to an optional model.
    func testOptionalGenericSpellingIsOptional() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Link: Identifiable, Equatable, Sendable {
                var id: UUID
                var url: Optional<URL>
                @Ignored var cache: Optional<String>
                @Relation(deleteRule: .nullify) var owner: Optional<Person>
            }
            """,
            expandedSource: """
                struct Link: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var url: Optional<URL>
                    var cache: Optional<String>
                    var owner: Optional<Person>
                }

                @Model
                final class LinkModel: PersistableModel {
                    typealias Domain = Link

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
                    var url: Optional<URL>
                    @Relationship(deleteRule: .nullify) var owner: PersonModel? = nil

                    init(from domain: Link) throws {
                        self.id = domain.id
                        self.url = domain.url
                        self.owner = try domain.owner.map {
                            try PersonModel(from: $0)
                        }
                    }

                    func toDomain() throws -> Link {
                        Link(
                            id: id,
                            url: url,
                            cache: nil,
                            owner: try owner.map {
                                try $0.toDomain()
                            }
                        )
                    }

                    func update(from domain: Link) throws {
                        self.url = domain.url
                        self.owner = try SwiduxRelationCodec.reconcile(
                            self.owner, with: domain.owner, in: modelContext)
                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<LinkModel> {
                        FetchDescriptor<LinkModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<LinkModel> {
                        FetchDescriptor<LinkModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Link: PersistableEntity {
                    typealias Model = LinkModel
                }
                """,
            macros: persisted
        )
    }

    func testRelationToOptionalArrayIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Shelf: Identifiable, Equatable, Sendable {
                var id: UUID
                @Relation(deleteRule: .cascade) var books: [Book]?
            }
            """,
            expandedSource: """
                struct Shelf: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var books: [Book]?
                }

                @Model
                final class ShelfModel: PersistableModel {
                    typealias Domain = Shelf

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()

                    init(from domain: Shelf) throws {
                        self.id = domain.id
                    }

                    func toDomain() throws -> Shelf {
                        Shelf(
                            id: id
                        )
                    }

                    func update(from domain: Shelf) throws {

                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<ShelfModel> {
                        FetchDescriptor<ShelfModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<ShelfModel> {
                        FetchDescriptor<ShelfModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Shelf: PersistableEntity {
                    typealias Model = ShelfModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.relationShape, line: 4, column: 41)
            ],
            macros: persisted
        )
    }

    func testRelationInverseIsDiagnosed() throws {
        assertMacroExpansion(
            #"""
            @Persisted
            struct Deck: Identifiable, Equatable, Sendable {
                var id: UUID
                @Relation(deleteRule: .cascade, inverse: \CardModel.deck) var cards: [Card] = []
            }
            """#,
            expandedSource: """
                struct Deck: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var cards: [Card] = []
                }

                @Model
                final class DeckModel: PersistableModel {
                    typealias Domain = Deck

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
                    @Relationship(deleteRule: .cascade) var cards: [CardModel]? = nil

                    init(from domain: Deck) throws {
                        self.id = domain.id
                        self.cards = try domain.cards.map {
                            try CardModel(from: $0)
                        }
                    }

                    func toDomain() throws -> Deck {
                        Deck(
                            id: id,
                            cards: try (cards ?? []).map {
                                try $0.toDomain()
                            }
                        )
                    }

                    func update(from domain: Deck) throws {
                        self.cards = try SwiduxRelationCodec.reconcile(
                            self.cards, with: domain.cards, in: modelContext)
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
                DiagnosticSpec(message: Message.inverse, line: 4, column: 37)
            ],
            macros: persisted
        )
    }

    func testInlineColumnCollisionIsDiagnosed() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Blob: Identifiable, Equatable, Sendable {
                var id: UUID
                @Inline var payload: Payload = Payload()
                var payloadData: Data = Data()
            }
            """,
            expandedSource: """
                struct Blob: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var payload: Payload = Payload()
                    var payloadData: Data = Data()
                }

                @Model
                final class BlobModel: PersistableModel {
                    typealias Domain = Blob

                    private static let swiduxInlineEncoder = JSONEncoder()
                    private static let swiduxInlineDecoder = JSONDecoder()
                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
                    private var payloadData: Data = Data()
                    var payload: Payload {
                        get throws {
                            try SwiduxInlineCodec.decode(Payload.self, from: payloadData, decoder: \
                Self.swiduxInlineDecoder, model: "BlobModel", property: "payload") ?? Payload()
                        }
                    }
                    var payloadData: Data = Data()

                    init(from domain: Blob) throws {
                        self.id = domain.id
                        self.payloadData = try Self.swiduxInlineEncoder.encode(domain.payload)
                        self.payloadData = domain.payloadData
                    }

                    func toDomain() throws -> Blob {
                        Blob(
                            id: id,
                            payload: try payload,
                            payloadData: payloadData
                        )
                    }

                    func update(from domain: Blob) throws {
                        self.payloadData = try Self.swiduxInlineEncoder.encode(domain.payload)
                        self.payloadData = domain.payloadData
                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<BlobModel> {
                        FetchDescriptor<BlobModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<BlobModel> {
                        FetchDescriptor<BlobModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Blob: PersistableEntity {
                    typealias Model = BlobModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.inlineCollision, line: 4, column: 17)
            ],
            macros: persisted
        )
    }

    // Several offenders in one struct each get their own location.
    func testPropertyDiagnosticsAreAnchoredOnEachProperty() throws {
        assertMacroExpansion(
            """
            @Persisted
            struct Messy: Identifiable, Equatable, Sendable {
                var id: UUID
                var link: URL
                @Ignored var badge: String
            }
            """,
            expandedSource: """
                struct Messy: Identifiable, Equatable, Sendable {
                    var id: UUID
                    var link: URL
                    var badge: String
                }

                @Model
                final class MessyModel: PersistableModel {
                    typealias Domain = Messy

                    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
                    var link: URL

                    init(from domain: Messy) throws {
                        self.id = domain.id
                        self.link = domain.link
                    }

                    func toDomain() throws -> Messy {
                        Messy(
                            id: id,
                            link: link,
                            badge: nil
                        )
                    }

                    func update(from domain: Messy) throws {
                        self.link = domain.link
                    }

                    static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<MessyModel> {
                        FetchDescriptor<MessyModel>(predicate: #Predicate {
                                ids.contains($0.id)
                            })
                    }

                    static func swiduxBatchFetchDescriptor(
                        persistentIDs: [PersistentIdentifier]
                    ) -> FetchDescriptor<MessyModel> {
                        FetchDescriptor<MessyModel>(predicate: #Predicate {
                            persistentIDs.contains($0.persistentModelID)
                        })
                    }
                }

                extension Messy: PersistableEntity {
                    typealias Model = MessyModel
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: Message.mirrorDefault, line: 4, column: 9),
                DiagnosticSpec(message: Message.ignoredOptional, line: 5, column: 18),
            ],
            macros: persisted
        )
    }
}

/// The diagnostic texts, spelled once so each test reads as its shape.
private enum Message {
    static let ifConfig =
        "Stored properties inside #if are not supported; they are invisible to the macro, so their values would silently reset instead of being observed/persisted. Declare the property unconditionally and move the #if into its type or value"
    static let tuple =
        "Declare each stored property with a plain name (var a: Int); a tuple-pattern property is invisible to the macro, so its values would silently reset instead of being observed/persisted"
    static let lazy =
        "lazy stored properties are not supported; the generated code reads every stored property from an immutable value, which can't run a lazy initializer. Store the value eagerly or make it computed"
    static let genericSwidux =
        "@Swidux can't be applied to a generic struct; the generated peer is a separate declaration that can't name the struct's generic parameters. Hand-write the SwiduxObservable conformance instead"
    static let genericPersisted =
        "@Persisted can't be applied to a generic struct; the generated peer is a separate declaration that can't name the struct's generic parameters"
    static let sliceType =
        "@Slice requires the property's type to name a @Swidux struct directly (UIState or Feature.UIState), not an optional, collection, or generic type"
    static let initializedLet =
        "A let with an initial value can't be persisted: the memberwise initializer has no parameter for it, so the generated model can't load it. Make it a var, or static if it is a constant"
    static let privateProperty =
        "@Persisted can't mirror a private property; the generated model reads and rebuilds it from outside the struct. Make it fileprivate or wider, or mark it @Ignored"
    static let relationShape =
        "@Relation properties must be declared as [T] (to-many) or T? (to-one), where T names a @Persisted struct directly"
    static let inverse =
        "@Relation(inverse:) is not supported: a @Relation is an owned value composition, and a domain value can't hold a back-reference to its parent without containing itself. Remove inverse:, and keep the parent's id in a @ForeignKey property if the child needs it"
    static let inlineCollision =
        "@Inline property 'payload' stores its blob in a generated 'payloadData' column, which collides with the property 'payloadData'; rename one of them"
    static let mirrorDefault =
        "Persisted properties of a non-primitive type must provide a default value (= …), be optional, or be marked @Inline to be CloudKit-safe"
    static let ignoredOptional =
        "@Ignored properties must be optional so they can be reconstructed as nil when loading from storage"

    static func restrictedAccess(_ macro: String) -> String {
        "@\(macro) can't be applied to a private or fileprivate struct; the generated peer declarations must name its type from outside it. Make the struct internal or wider"
    }

    static func nested(_ name: String, in enclosing: String, _ declaration: String) -> String {
        "Nested type '\(name)' must be written with its qualified name '\(enclosing).\(name)'; the generated \(declaration) is emitted as a peer outside the struct, where the bare name doesn't resolve"
    }

    static func selfDefault(_ enclosing: String, _ declaration: String) -> String {
        "'Self' in a property's type or default value must be written as '\(enclosing)'; the generated \(declaration) is emitted outside the struct, where Self doesn't refer to it"
    }
}
#endif
