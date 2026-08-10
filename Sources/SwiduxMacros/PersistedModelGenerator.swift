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
        modelMemberLines(for: $0, accessPrefix: accessPrefix, modelName: modelName)
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

    let source = """
        @Model
        \(accessPrefix)final class \(modelName): PersistableModel {
            \(accessPrefix)typealias Domain = \(structName)

        \(codecMembers)\(memberLines)

            \(accessPrefix)init(from domain: \(structName)) {
        \(initLines)
            }

            \(accessPrefix)func toDomain() -> \(structName) {
                \(structName)(
        \(toDomainArgs)
                )
            }

            \(accessPrefix)func update(from domain: \(structName)) {
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
func generatePersistableEntityExtension(
    structName: String,
    accessLevel: String?
) -> ExtensionDeclSyntax {
    let accessPrefix = accessLevel.map { "\($0) " } ?? ""
    let source = """
        extension \(structName): PersistableEntity {
            \(accessPrefix)typealias Model = \(structName)Model
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

private func relationModelType(cardinality: RelationCardinality, element: String) -> String {
    // All relationships are optional: CloudKit forbids non-optional relationships.
    switch cardinality {
    case .toMany: return "[\(element)Model]?"
    case .toOneOptional, .toOne: return "\(element)Model?"
    }
}

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

private func relationshipAttribute(deleteRule: String?, inverse: String?) -> String {
    var parts: [String] = []
    if let deleteRule { parts.append("deleteRule: \(deleteRule)") }
    if let inverse { parts.append("inverse: \(inverse)") }
    return parts.isEmpty ? "@Relationship" : "@Relationship(\(parts.joined(separator: ", ")))"
}

private func modelMemberLines(
    for prop: PersistedProperty,
    accessPrefix: String,
    modelName: String
) -> String? {
    let type = prop.typeSyntax.trimmedDescription
    switch prop.kind {
    case .mirror:
        let suffix: String
        switch cloudKitMirrorDefault(for: prop) {
        case .explicit(let value): suffix = " = \(value)"
        case .notNeeded, .missing: suffix = ""
        }
        return "    \(identityAttribute(for: prop))\(accessPrefix)var \(prop.name): \(type)\(suffix)"
    case .inlineBlob:
        // The backing column defaults to `Data()` (CloudKit-safe), which is
        // never decodable — a row materialized with defaults (e.g. created by
        // CloudKit before the blob syncs) hits the fallback, so it must never
        // trap. Non-optional blobs fall back to the domain default the macro
        // requires (`inlineRequiresDefault`); optional blobs fall back to nil.
        guard let fallback = prop.isOptional ? "nil" : prop.defaultExpr else {
            // No recoverable fallback exists; `inlineRequiresDefault` is
            // diagnosed as an error, so this expansion never compiles.
            return """
                    private var \(prop.name)Data: Data = Data()
                    \(accessPrefix)var \(prop.name): \(type) {
                        get {
                            do { return try Self.swiduxInlineDecoder.decode(\(type).self, from: \(prop.name)Data) }
                            catch { fatalError("Swidux @Inline: failed to decode \(prop.name): \\(error)") }
                        }
                        set { \(prop.name)Data = (try? Self.swiduxInlineEncoder.encode(newValue)) ?? Data() }
                    }
                """
        }
        // Decode through SwiduxInlineCodec so an undecodable blob (schema
        // drift, corruption) logs before falling back — a silent `try?` here
        // would let the next save overwrite the old payload with the default.
        let getter =
            "SwiduxInlineCodec.decode(\(type).self, from: \(prop.name)Data, decoder: Self.swiduxInlineDecoder, model: \"\(modelName)\", property: \"\(prop.name)\") ?? \(fallback)"
        return """
                private var \(prop.name)Data: Data = Data()
                \(accessPrefix)var \(prop.name): \(type) {
                    get { \(getter) }
                    set { \(prop.name)Data = (try? Self.swiduxInlineEncoder.encode(newValue)) ?? Data() }
                }
            """
    case .relation(let rule, let inverse, let cardinality, let element):
        let attr = relationshipAttribute(deleteRule: rule, inverse: inverse)
        let modelType = relationModelType(cardinality: cardinality, element: element)
        return "    \(attr) \(accessPrefix)var \(prop.name): \(modelType) = nil"
    case .ignored:
        return nil
    }
}

private func initLine(for prop: PersistedProperty) -> String? {
    switch prop.kind {
    case .mirror:
        return "        self.\(prop.name) = domain.\(prop.name)"
    case .inlineBlob:
        return "        self.\(prop.name)Data = (try? Self.swiduxInlineEncoder.encode(domain.\(prop.name))) ?? Data()"
    case .relation(_, _, let cardinality, let element):
        switch cardinality {
        case .toMany, .toOneOptional:
            return "        self.\(prop.name) = domain.\(prop.name).map { \(element)Model(from: $0) }"
        case .toOne:
            return "        self.\(prop.name) = \(element)Model(from: domain.\(prop.name))"
        }
    case .ignored:
        return nil
    }
}

private func toDomainArgument(for prop: PersistedProperty) -> String {
    switch prop.kind {
    case .mirror, .inlineBlob:
        return "            \(prop.name): \(prop.name)"
    case .relation(_, _, let cardinality, _):
        // The model stores relationships optionally (CloudKit requirement), so
        // reconstruct the domain shape from the optional.
        switch cardinality {
        case .toMany:
            return "            \(prop.name): (\(prop.name) ?? []).map { $0.toDomain() }"
        case .toOneOptional:
            return "            \(prop.name): \(prop.name).map { $0.toDomain() }"
        case .toOne:
            return "            \(prop.name): \(prop.name)!.toDomain()"
        }
    case .ignored:
        return "            \(prop.name): nil"
    }
}

private func updateLine(for prop: PersistedProperty) -> String? {
    // Identity is stable; never reassign it on update.
    if prop.isIdentity { return nil }
    switch prop.kind {
    case .mirror, .inlineBlob:
        return "        self.\(prop.name) = domain.\(prop.name)"
    case .relation(_, _, let cardinality, let element):
        switch cardinality {
        case .toMany, .toOneOptional:
            return "        self.\(prop.name) = domain.\(prop.name).map { \(element)Model(from: $0) }"
        case .toOne:
            return "        self.\(prop.name) = \(element)Model(from: domain.\(prop.name))"
        }
    case .ignored:
        return nil
    }
}
