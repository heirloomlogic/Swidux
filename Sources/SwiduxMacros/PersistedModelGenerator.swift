import SwiftParser
import SwiftSyntax

/// Generates the SwiftData `@Model` shadow class for an `@Persisted` struct,
/// conforming it to `PersistableModel` with the `init(from:)`/`toDomain()`/
/// `update(from:)` converter trio.
func generatePersistedModelClass(
    structName: String,
    properties: [PersistedProperty],
    accessLevel: String?
) -> DeclSyntax {
    let modelName = "\(structName)Model"
    let accessPrefix = accessLevel.map { "\($0) " } ?? ""

    let memberLines = properties.compactMap {
        modelMemberLines(
            for: $0,
            accessPrefix: memberAccessPrefix(structAccess: accessLevel, member: $0.accessLevel),
            modelName: modelName
        )
    }
    .joined(separator: "\n")
    // Shared codec for @Inline blob columns, allocated once per model type
    // rather than on every property access.
    let hasInline = properties.contains { if case .inlineBlob = $0.kind { true } else { false } }
    let codecMembers =
        hasInline
        ? "    private static let swiduxInlineEncoder = JSONEncoder()\n    private static let swiduxInlineDecoder = JSONDecoder()\n"
        : ""
    let initLines = properties.compactMap { initLine(for: $0) }
        .joined(separator: "\n")
    let toDomainArgs = properties.map { toDomainArgument(for: $0) }
        .joined(separator: ",\n")
    let updateLines = properties.compactMap { updateLine(for: $0) }
        .joined(separator: "\n")

    let associationProperties = properties.filter { if case .association = $0.kind { true } else { false } }
    let associationMembers: String
    if associationProperties.isEmpty {
        associationMembers = ""
    } else {
        let descriptors = associationProperties.map { prop -> String in
            guard case .association(let toMany, let destination, let inverse) = prop.kind else { fatalError() }
            let constructor = toMany ? "hasMany" : "belongsTo"
            let idArgument = toMany ? "ids" : "id"
            return
                "            .\(constructor)(property: \"\(prop.name)\", inverse: \"\(inverse)\", destination: \(destination).self, \(idArgument): \\\(modelName).\(prop.name), reference: \\\(modelName)._swidux_\(prop.name)Reference)"
        }.joined(separator: ",\n")
        associationMembers = """

                \(accessPrefix)static var swiduxAssociations: [SwiduxAssociationDescriptor<\(modelName)>] {
                    [
            \(descriptors)
                    ]
                }
            """
    }

    let source = """
        @Model
        \(accessPrefix)final class \(modelName): PersistableModel {
            \(accessPrefix)typealias Domain = \(structName)

        \(codecMembers)\(memberLines)\(associationMembers)

            \(accessPrefix)init(from domain: \(structName)) throws {
        \(initLines)
            }

            \(accessPrefix)func toDomain() throws -> \(structName) {
                \(structName)(
        \(toDomainArgs)
                )
            }

            \(accessPrefix)func update(from domain: \(structName)) throws {
        \(updateLines)
            }

            \(accessPrefix)static func swiduxBatchFetchDescriptor(ids: [UUID]) -> FetchDescriptor<\(modelName)> {
                FetchDescriptor<\(modelName)>(predicate: #Predicate { ids.contains($0.id) })
            }

            \(accessPrefix)static func swiduxBatchFetchDescriptor(
                persistentIDs: [PersistentIdentifier]
            ) -> FetchDescriptor<\(modelName)> {
                FetchDescriptor<\(modelName)>(predicate: #Predicate {
                    persistentIDs.contains($0.persistentModelID)
                })
            }
        }
        """

    return DeclSyntax(stringLiteral: source)
}

/// Generates `extension <Struct>: PersistableEntity { typealias Model = <Struct>Model }`.
///
/// `typeName` is the extended type as the compiler names it — qualified when the
/// struct is nested (`Library.Book`) — and the model peer, declared beside the
/// struct, is named by appending `Model` to it (`Library.BookModel`).
func generatePersistableEntityExtension(
    typeName: String,
    accessLevel: String?,
    properties: [PersistedProperty] = []
) -> ExtensionDeclSyntax {
    let accessPrefix = accessLevel.map { "\($0) " } ?? ""
    let associations = properties.filter { if case .association = $0.kind { true } else { false } }
    let inverseMember: String
    if associations.isEmpty {
        inverseMember = ""
    } else {
        let cases = associations.map {
            "            case \"\($0.name)\": return \\\(typeName)Model._swidux_\($0.name)Reference"
        }.joined(separator: "\n")
        inverseMember = """

                \(accessPrefix)static func swiduxAssociationInverse(_ property: String) -> AnyKeyPath? {
                    switch property {
            \(cases)
                    default: return nil
                    }
                }
            """
    }
    let source = """
        extension \(typeName): PersistableEntity {
            \(accessPrefix)typealias Model = \(typeName)Model\(inverseMember)
        }
        """
    let sourceFile = Parser.parse(source: source)
    guard let firstStatement = sourceFile.statements.first else {
        fatalError("Failed to parse generated PersistableEntity extension")
    }
    return firstStatement.item.cast(ExtensionDeclSyntax.self)
}

// MARK: - CloudKit-safe defaults

/// The default a CloudKit-safe model needs for a mirrored attribute. SwiftData's
/// CloudKit mirroring requires every non-optional attribute to be optional or
/// carry a `= default`, validated when the `ModelContainer` is created.
enum MirrorDefault: Equatable {
    /// Emit `= <expr>` — a user-supplied default or a canonical primitive default.
    case explicit(String)
    /// Optional attribute: CloudKit-safe with no default.
    case notNeeded
    /// Non-optional, non-primitive, no user default — the macro must diagnose this.
    case missing
}

/// Canonical default expressions for the SwiftData primitive scalar types the
/// macro can default without knowing the concrete type. Anything not listed
/// (custom `Codable` types, `URL`, enums) must be optional, carry a user
/// default, or use `@Inline`.
private let primitiveDefaults: [String: String] = [
    "String": "\"\"",
    "Bool": "false",
    "Int": "0", "Int8": "0", "Int16": "0", "Int32": "0", "Int64": "0",
    "UInt": "0", "UInt8": "0", "UInt16": "0", "UInt32": "0", "UInt64": "0",
    "Double": "0", "Float": "0", "CGFloat": "0",
    "Date": "Date.distantPast",
    "Data": "Data()",
    "UUID": "UUID()",
]

/// Resolves the CloudKit-safe default for a mirrored property. Shared by the
/// generator (which emits the `= …`) and the macro (which diagnoses `.missing`)
/// so the two never disagree about which properties are safe.
func cloudKitMirrorDefault(for prop: PersistedProperty) -> MirrorDefault {
    if let userDefault = prop.defaultExpr { return .explicit(userDefault) }
    if prop.isOptional { return .notNeeded }
    if let primitive = primitiveDefaults[prop.typeSyntax.trimmedDescription] { return .explicit(primitive) }
    return .missing
}

// MARK: - Per-property code generation

/// The attribute prefix for a mirrored identity column, empty for anything else.
///
/// SwiftData drops a deleted row's values from persistent history unless they are
/// marked `.preserveValueOnDeletion`, leaving a delete transaction that records
/// *something* went away without recording what — which is all a peer device has
/// to go on. Only the identity is preserved: a tombstone outlives the row, so
/// anything added here is data that deletion does not actually delete.
private func identityAttribute(for prop: PersistedProperty) -> String {
    prop.isIdentity ? "@Attribute(.preserveValueOnDeletion) " : ""
}

private func modelMemberLines(
    for prop: PersistedProperty,
    accessPrefix: String,
    modelName: String
) -> String? {
    let type = prop.typeSyntax.trimmedDescription
    switch prop.kind {
    case .mirror, .association:
        let suffix: String
        switch cloudKitMirrorDefault(for: prop) {
        case .explicit(let value): suffix = " = \(value)"
        case .notNeeded, .missing: suffix = ""
        }
        let scalar = "    \(identityAttribute(for: prop))\(accessPrefix)var \(prop.name): \(type)\(suffix)"
        if case .association(let toMany, let destination, let inverse) = prop.kind {
            let referenceType = toMany ? "[\(destination)Model]?" : "\(destination)Model?"
            return scalar
                + "\n    @Relationship(deleteRule: .nullify, inverse: associationInverse(\(destination).self, \"\(inverse)\")) \(accessPrefix)var _swidux_\(prop.name)Reference: \(referenceType) = nil"
        }
        return scalar
    case .inlineBlob:
        // Empty columns are CloudKit defaults. Non-empty invalid payloads
        // throw so a read cannot turn corruption into a successful default.
        let fallback = prop.isOptional ? "nil" : prop.defaultExpr
        let decode =
            "try SwiduxInlineCodec.decode(\(type).self, from: _swidux_\(prop.name)Data, decoder: Self.swiduxInlineDecoder, model: \"\(modelName)\", property: \"\(prop.name)\")"
        let getter =
            fallback.map { "\(decode) ?? \($0)" }
            ?? "try Self.swiduxInlineDecoder.decode(\(type).self, from: _swidux_\(prop.name)Data)"
        return """
                private var _swidux_\(prop.name)Data: Data = Data()
                \(accessPrefix)var \(prop.name): \(type) {
                    get throws { \(getter) }
                }
            """
    case .ignored:
        return nil
    }
}

private func initLine(for prop: PersistedProperty) -> String? {
    switch prop.kind {
    case .mirror, .association:
        return "        self.\(prop.name) = domain.\(prop.name)"
    case .inlineBlob:
        return "        self._swidux_\(prop.name)Data = try Self.swiduxInlineEncoder.encode(domain.\(prop.name))"
    case .ignored:
        return nil
    }
}

private func toDomainArgument(for prop: PersistedProperty) -> String {
    switch prop.kind {
    case .mirror, .association:
        return "            \(prop.name): \(prop.name)"
    case .inlineBlob:
        return "            \(prop.name): try \(prop.name)"
    case .ignored:
        return "            \(prop.name): nil"
    }
}

private func updateLine(for prop: PersistedProperty) -> String? {
    // Identity is stable; never reassign it on update.
    if prop.isIdentity { return nil }
    switch prop.kind {
    case .mirror, .association:
        return "        self.\(prop.name) = domain.\(prop.name)"
    case .inlineBlob:
        return "        self._swidux_\(prop.name)Data = try Self.swiduxInlineEncoder.encode(domain.\(prop.name))"
    case .ignored:
        return nil
    }
}
