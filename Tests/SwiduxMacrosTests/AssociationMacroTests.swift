import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import XCTest

#if canImport(SwiduxMacros)
@testable import SwiduxMacros

final class AssociationMacroTests: XCTestCase {
    private func expand(_ source: String) throws -> (String, [String]) {
        let declaration = Parser.parse(source: source).statements.first!.item.cast(StructDeclSyntax.self)
        let context = BasicMacroExpansionContext()
        let attribute = declaration.attributes.first!.as(AttributeSyntax.self)!
        let peers = try PersistedMacro.expansion(of: attribute, providingPeersOf: declaration, in: context)
        let extensions = try PersistedMacro.expansion(
            of: attribute, attachedTo: declaration,
            providingExtensionsOf: IdentifierTypeSyntax(name: declaration.name), conformingTo: [], in: context)
        return (
            (peers.map(\.description) + extensions.map(\.description)).joined(separator: "\n"),
            context.diagnostics.map(\.message)
        )
    }

    func testBelongsToUsesScalarIdentityAndStorageOnlyInverse() throws {
        let (source, diagnostics) = try expand(
            """
            @Persisted struct Child {
                var id: UUID
                @BelongsTo(Parent.self, inverse: "childIDs") var parentID: UUID?
            }
            """)
        XCTAssertEqual(diagnostics, [])
        XCTAssertTrue(source.contains("var parentID: UUID?"))
        XCTAssertTrue(
            source.contains(
                "@Relationship(deleteRule: .nullify, inverse: associationInverse(Parent.self, \"childIDs\"))"))
        XCTAssertTrue(source.contains("var _swidux_parentIDReference: ParentModel? = nil"))
        XCTAssertTrue(source.contains("parentID: parentID"))
        XCTAssertFalse(source.contains("ParentModel(from:"))
        XCTAssertTrue(source.contains("return \\ChildModel._swidux_parentIDReference"))
        XCTAssertTrue(
            source.contains(
                ".belongsTo(property: \"parentID\", inverse: \"childIDs\", destination: Parent.self, id: \\ChildModel.parentID, reference: \\ChildModel._swidux_parentIDReference)"
            ))
    }

    func testHasManyAndMultipleNamedEndpoints() throws {
        let (source, diagnostics) = try expand(
            """
            @Persisted struct Parent {
                var id: UUID
                @HasMany(Child.self, inverse: "ownerID") var childIDs: [UUID] = []
                @HasMany(Child.self, inverse: "reviewerID") var reviewIDs: [UUID] = []
            }
            """)
        XCTAssertEqual(diagnostics, [])
        XCTAssertTrue(source.contains("var _swidux_childIDsReference: [ChildModel]? = nil"))
        XCTAssertTrue(source.contains("var _swidux_reviewIDsReference: [ChildModel]? = nil"))
        XCTAssertTrue(source.contains("self.childIDs = domain.childIDs"))
        XCTAssertTrue(
            source.contains(
                ".hasMany(property: \"childIDs\", inverse: \"ownerID\", destination: Child.self, ids: \\ParentModel.childIDs, reference: \\ParentModel._swidux_childIDsReference)"
            ))
    }

    func testInvalidShapesAreDiagnosed() throws {
        let (_, diagnostics) = try expand(
            """
            @Persisted struct Invalid {
                var id: UUID
                @BelongsTo(Parent.self, inverse: "childIDs") var parentID: UUID
                @HasMany(Child.self, inverse: "parentID") var children: [Child] = []
            }
            """)
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertTrue(diagnostics.contains { $0.contains("@BelongsTo requires a UUID?") })
        XCTAssertTrue(diagnostics.contains { $0.contains("@HasMany requires a [UUID]") })
    }

    func testOrdinaryDataSuffixDoesNotCollideWithInlineStorage() throws {
        let (source, diagnostics) = try expand(
            """
            @Persisted struct Payload {
                var id: UUID
                @Inline var content: String = ""
                var contentData: Data
            }
            """)
        XCTAssertEqual(diagnostics, [])
        XCTAssertTrue(source.contains("private var _swidux_contentData: Data = Data()"))
        XCTAssertTrue(source.contains("var contentData: Data = Data()"))
    }

    func testAssociationArgumentsMustBeStaticTypeAndPropertyNames() throws {
        let (_, diagnostics) = try expand(
            """
            @Persisted struct InvalidArguments {
                var id: UUID
                @BelongsTo(makeParent().self, inverse: "children") var firstID: UUID?
                @BelongsTo(Parent.self, inverse: "children.name") var secondID: UUID?
                @HasMany(Child.self, inverse: endpointName) var childIDs: [UUID] = []
            }
            """)
        XCTAssertEqual(diagnostics.count, 3)
        XCTAssertTrue(diagnostics.allSatisfy { $0.contains("inverse property name string") })
    }

    func testReservedColumnsAreDiagnosedAndInlineIsHygienic() throws {
        let (source, diagnostics) = try expand(
            """
            @Persisted struct Collision {
                var id: UUID
                @Inline var payload: String = ""
                var _swidux_payloadData: Data
                @BelongsTo(Parent.self, inverse: "childIDs") var parentID: UUID?
                var _swidux_parentIDReference: UUID?
            }
            """)
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertTrue(source.contains("private var _swidux_payloadData: Data = Data()"))
        XCTAssertTrue(diagnostics.contains { $0.contains("_swidux_parentIDReference") })
        XCTAssertTrue(diagnostics.contains { $0.contains("_swidux_payloadData") })
    }
}
#endif
