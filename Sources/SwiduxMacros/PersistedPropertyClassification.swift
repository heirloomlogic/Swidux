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
    case relation(deleteRule: String?, cardinality: RelationCardinality, elementBaseName: String)
    /// `@Ignored`: a derived/denormalized field with no column. Must be optional
    /// (or otherwise defaultable) so `toDomain()` can reconstruct it as `nil`.
    case ignored
    case association(toMany: Bool, destination: String, inverse: String)
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
    let defaultValue: ExprSyntax?
    /// The property's binding, where property-level diagnostics are anchored.
    let binding: PatternBindingSyntax
    /// The `@Relation` attribute's `inverse:` argument, if one was written.
    /// Always diagnosed: see `SwiduxDiagnostic.relationInverseUnsupported`.
    let relationInverse: LabeledExprSyntax?
    /// Whether a `@Relation`'s declared type has a shape the generator can
    /// map: `[T]`, `T?` or `T`, with `T` naming a type directly.
    let hasSupportedRelationShape: Bool
    /// The access level the property spells, if any; the generated model never
    /// republishes it wider. See `memberAccessPrefix`.
    let accessLevel: AccessLevel?

    /// `defaultValue` as source text, the form the generator emits.
    var defaultExpr: String? { defaultValue?.trimmedDescription }

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
        // Accept both `var` and `let` stored properties; skip type-level and
        // computed ones.
        guard
            varDecl.bindingSpecifier.tokenKind == .keyword(.var)
                || varDecl.bindingSpecifier.tokenKind == .keyword(.let),
            !isTypeMember(varDecl),
            !isLazy(varDecl)
        else { return nil }
        guard let binding = varDecl.bindings.first,
            isStoredBinding(binding),
            !isInitializedLet(varDecl),
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
            let typeAnnotation = binding.typeAnnotation
        else { return nil }

        let name = pattern.identifier.text
        let typeSyntax = typeAnnotation.type
        let isOptional = optionalWrappedType(of: typeSyntax) != nil
        let defaultValue = binding.initializer?.value

        func property(
            _ kind: PersistedPropertyKind,
            inverse: LabeledExprSyntax? = nil,
            supportedShape: Bool = true
        ) -> PersistedProperty {
            PersistedProperty(
                name: name,
                typeSyntax: typeSyntax,
                kind: kind,
                isOptional: isOptional,
                defaultValue: defaultValue,
                binding: binding,
                relationInverse: inverse,
                hasSupportedRelationShape: supportedShape,
                accessLevel: AccessLevel(varDecl.modifiers)
            )
        }

        if marker(named: "Ignored", on: varDecl) != nil {
            return property(.ignored)
        }
        if let relation = marker(named: "Relation", on: varDecl) {
            let (rule, inverse) = relationArguments(relation)
            let shape = relationShape(of: typeSyntax)
            return property(
                .relation(deleteRule: rule, cardinality: shape.cardinality, elementBaseName: shape.element),
                inverse: inverse,
                supportedShape: shape.isSupported
            )
        }
        for (markerName, toMany) in [("BelongsTo", false), ("HasMany", true)] {
            if let attribute = marker(named: markerName, on: varDecl) {
                let arguments = associationArguments(attribute)
                return property(
                    .association(toMany: toMany, destination: arguments.destination, inverse: arguments.inverse),
                    supportedShape: associationShape(typeSyntax, toMany: toMany) && arguments.valid
                )
            }
        }
        if marker(named: "Inline", on: varDecl) != nil {
            return property(.inlineBlob)
        }
        // `@ForeignKey` is a documentation/intent marker; functionally a scalar
        // column, so it falls through to `.mirror`.
        return property(.mirror)
    }
}

/// Whether a declaration is a `let` with an initial value. Swift leaves such a
/// property out of the memberwise initializer, so the generated `toDomain()`
/// has no way to pass it back; `@Persisted` diagnoses it and skips it here.
func isInitializedLet(_ varDecl: VariableDeclSyntax) -> Bool {
    varDecl.bindingSpecifier.tokenKind == .keyword(.let) && varDecl.bindings.first?.initializer != nil
}

/// The wrapped type when `type` is optional — spelled `T?`, `T!`,
/// `Optional<T>` or `Swift.Optional<T>` — and `nil` otherwise.
func optionalWrappedType(of type: TypeSyntax) -> TypeSyntax? {
    if let optional = type.as(OptionalTypeSyntax.self) {
        return optional.wrappedType
    }
    if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        return unwrapped.wrappedType
    }
    let generic: (name: String, arguments: GenericArgumentClauseSyntax?)?
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        generic = (identifier.name.text, identifier.genericArgumentClause)
    } else if let member = type.as(MemberTypeSyntax.self),
        member.baseType.as(IdentifierTypeSyntax.self)?.name.text == "Swift"
    {
        generic = (member.name.text, member.genericArgumentClause)
    } else {
        generic = nil
    }
    guard let generic, generic.name == "Optional", let arguments = generic.arguments?.arguments,
        arguments.count == 1, let argument = arguments.first
    else { return nil }
    // Built through `Syntax` because the argument's static type differs across
    // swift-syntax releases (a type, or a type-or-expression choice).
    return TypeSyntax(Syntax(argument.argument))
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

/// Extracts the `deleteRule:` source text and the `inverse:` argument from a
/// `@Relation`.
private func relationArguments(_ attribute: AttributeSyntax) -> (deleteRule: String?, inverse: LabeledExprSyntax?) {
    guard case .argumentList(let args) = attribute.arguments else { return (nil, nil) }
    var rule: String?
    var inverse: LabeledExprSyntax?
    for arg in args {
        switch arg.label?.text {
        case "deleteRule":
            rule = arg.expression.trimmedDescription
        case "inverse":
            inverse = arg
        default:
            break
        }
    }
    return (rule, inverse)
}

/// Determines the cardinality and related element base type name of a relation
/// property from its declared type (`[Foo]`, `Foo?`, or `Foo`).
///
/// `isSupported` is `false` when the element doesn't name a type directly —
/// `[Foo]?`, `[[Foo]]`, `Set<Foo>` — since appending `Model` to it names nothing.
private func relationShape(
    of typeSyntax: TypeSyntax
) -> (cardinality: RelationCardinality, element: String, isSupported: Bool) {
    let cardinality: RelationCardinality
    let element: TypeSyntax
    if let array = typeSyntax.as(ArrayTypeSyntax.self) {
        (cardinality, element) = (.toMany, array.element)
    } else if let wrapped = optionalWrappedType(of: typeSyntax) {
        (cardinality, element) = (.toOneOptional, wrapped)
    } else {
        (cardinality, element) = (.toOne, typeSyntax)
    }
    return (cardinality, baseName(of: element), isDirectlyNamedType(element))
}

private func baseName(of typeSyntax: TypeSyntax) -> String {
    if let identifier = typeSyntax.as(IdentifierTypeSyntax.self) {
        return identifier.name.text
    }
    return typeSyntax.trimmedDescription
}

/// Association endpoints use scalar UUIDs; model references are storage-only.
private func associationShape(_ type: TypeSyntax, toMany: Bool) -> Bool {
    let element: TypeSyntax?
    if toMany {
        element = type.as(ArrayTypeSyntax.self)?.element
    } else {
        element = optionalWrappedType(of: type)
    }
    guard let element else { return false }
    return ["UUID", "Foundation.UUID"].contains(element.trimmedDescription)
}

private func associationArguments(_ attribute: AttributeSyntax) -> (destination: String, inverse: String, valid: Bool) {
    guard case .argumentList(let arguments) = attribute.arguments,
        let destination = arguments.first?.expression.as(MemberAccessExprSyntax.self),
        destination.declName.baseName.text == "self", let base = destination.base,
        let inverse = arguments.first(where: { $0.label?.text == "inverse" })?.expression.as(
            StringLiteralExprSyntax.self),
        inverse.segments.count == 1,
        let segment = inverse.segments.first?.as(StringSegmentSyntax.self)
    else { return ("Invalid", "", false) }
    let name = segment.content.text
    let validName =
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        && !(name.first?.isNumber ?? true)
    return (base.trimmedDescription, name, validName && directlyNamedDestination(base))
}

private func directlyNamedDestination(_ expression: ExprSyntax) -> Bool {
    if expression.is(DeclReferenceExprSyntax.self) { return true }
    if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
        return directlyNamedDestination(base)
    }
    return false
}
