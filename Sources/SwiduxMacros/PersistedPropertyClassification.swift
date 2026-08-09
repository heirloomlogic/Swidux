import SwiftSyntax

/// How a property on an `@Persisted` domain struct maps onto the generated
/// SwiftData `@Model` shadow class.
enum PersistedPropertyKind {
    /// Mirror the property directly onto the model (`var name: T`). SwiftData
    /// persists scalars and `Codable` composites natively. This is the default.
    case mirror
    /// `@Inline`: force a `Codable` value into one opaque JSON `Data` column,
    /// exposed through a computed accessor of the original type.
    case inlineBlob
    /// `@Relation`: a SwiftData relationship to another `@Persisted` entity's
    /// generated model. `elementBaseName` is the related domain type's name.
    case relation(deleteRule: String?, inverse: String?, cardinality: RelationCardinality, elementBaseName: String)
    /// `@Ignored`: a derived/denormalized field with no column. Must be optional
    /// (or otherwise defaultable) so `toDomain()` can reconstruct it as `nil`.
    case ignored
}

enum RelationCardinality {
    case toOne
    case toOneOptional
    case toMany
}

struct PersistedProperty {
    let name: String
    let typeSyntax: TypeSyntax
    let kind: PersistedPropertyKind
    let isOptional: Bool
    /// The default-value expression the user wrote on the domain property
    /// (`var x: T = <expr>`), if any. Propagated onto the generated model so
    /// non-optional attributes are CloudKit-safe.
    let defaultExpr: String?

    /// Whether this is the entity's identity column.
    ///
    /// Matching on the name is matching on the protocol: `PersistableEntity`
    /// refines `Identifiable` with `ID == UUID`, and `PersistableModel` requires
    /// `var id: UUID`, so Swift itself forces the identity property to be spelled
    /// `id`. The generator treats it specially in two places — it is preserved on
    /// deletion, and `update(from:)` never reassigns it — and both should mean the
    /// same thing.
    var isIdentity: Bool { name == "id" }
}

/// Classifies the stored properties of an `@Persisted` domain struct, reading
/// the `@Relation` / `@ForeignKey` / `@Inline` / `@Ignored` marker attributes.
func classifyPersistedProperties(of structDecl: StructDeclSyntax) -> [PersistedProperty] {
    structDecl.memberBlock.members.compactMap { member -> PersistedProperty? in
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return nil }
        // Accept both `var` and `let` stored properties; skip computed ones.
        guard
            varDecl.bindingSpecifier.tokenKind == .keyword(.var)
                || varDecl.bindingSpecifier.tokenKind == .keyword(.let)
        else { return nil }
        guard let binding = varDecl.bindings.first,
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
            let typeAnnotation = binding.typeAnnotation,
            binding.accessorBlock == nil
        else { return nil }

        let name = pattern.identifier.text
        let typeSyntax = typeAnnotation.type
        let isOptional = typeSyntax.is(OptionalTypeSyntax.self)
        let defaultExpr = binding.initializer?.value.trimmedDescription

        if marker(named: "Ignored", on: varDecl) != nil {
            return PersistedProperty(
                name: name, typeSyntax: typeSyntax, kind: .ignored, isOptional: isOptional, defaultExpr: defaultExpr)
        }
        if let relation = marker(named: "Relation", on: varDecl) {
            let (rule, inverse) = relationArguments(relation)
            let (cardinality, element) = relationShape(of: typeSyntax)
            return PersistedProperty(
                name: name,
                typeSyntax: typeSyntax,
                kind: .relation(deleteRule: rule, inverse: inverse, cardinality: cardinality, elementBaseName: element),
                isOptional: isOptional,
                defaultExpr: defaultExpr
            )
        }
        if marker(named: "Inline", on: varDecl) != nil {
            return PersistedProperty(
                name: name, typeSyntax: typeSyntax, kind: .inlineBlob, isOptional: isOptional, defaultExpr: defaultExpr)
        }
        // `@ForeignKey` is a documentation/intent marker; functionally a scalar
        // column, so it falls through to `.mirror`.
        return PersistedProperty(
            name: name, typeSyntax: typeSyntax, kind: .mirror, isOptional: isOptional, defaultExpr: defaultExpr)
    }
}

// MARK: - Attribute parsing helpers

/// Returns the `AttributeSyntax` for a marker macro of the given name, if present.
private func marker(named markerName: String, on varDecl: VariableDeclSyntax) -> AttributeSyntax? {
    for attribute in varDecl.attributes {
        guard case .attribute(let attr) = attribute,
            let identifier = attr.attributeName.as(IdentifierTypeSyntax.self)
        else { continue }
        if identifier.name.text == markerName {
            return attr
        }
    }
    return nil
}

/// Extracts `deleteRule:` and `inverse:` argument source text from a `@Relation`.
private func relationArguments(_ attribute: AttributeSyntax) -> (deleteRule: String?, inverse: String?) {
    guard case .argumentList(let args) = attribute.arguments else { return (nil, nil) }
    var rule: String?
    var inverse: String?
    for arg in args {
        switch arg.label?.text {
        case "deleteRule":
            rule = arg.expression.trimmedDescription
        case "inverse":
            inverse = arg.expression.trimmedDescription
        default:
            break
        }
    }
    return (rule, inverse)
}

/// Determines the cardinality and related element base type name of a relation
/// property from its declared type (`[Foo]`, `Foo?`, or `Foo`).
private func relationShape(of typeSyntax: TypeSyntax) -> (RelationCardinality, String) {
    if let array = typeSyntax.as(ArrayTypeSyntax.self) {
        return (.toMany, baseName(of: array.element))
    }
    if let optional = typeSyntax.as(OptionalTypeSyntax.self) {
        return (.toOneOptional, baseName(of: optional.wrappedType))
    }
    return (.toOne, baseName(of: typeSyntax))
}

private func baseName(of typeSyntax: TypeSyntax) -> String {
    if let identifier = typeSyntax.as(IdentifierTypeSyntax.self) {
        return identifier.name.text
    }
    return typeSyntax.trimmedDescription
}
