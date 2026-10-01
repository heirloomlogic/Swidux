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
    /// `@Ignored`: a derived/denormalized field with no column. Must be optional
    /// (or otherwise defaultable) so `toDomain()` can reconstruct it as `nil`.
    case ignored
    case association(toMany: Bool, destination: String, inverse: String)
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
    /// Whether an association marker's declared type and arguments can be
    /// represented by the generated model.
    let hasSupportedShape: Bool
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
/// the `@BelongsTo` / `@HasMany` / `@ForeignKey` / `@Inline` / `@Ignored` marker attributes.
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
            supportedShape: Bool = true
        ) -> PersistedProperty {
            PersistedProperty(
                name: name,
                typeSyntax: typeSyntax,
                kind: kind,
                isOptional: isOptional,
                defaultValue: defaultValue,
                binding: binding,
                hasSupportedShape: supportedShape,
                accessLevel: AccessLevel(varDecl.modifiers)
            )
        }

        if marker(named: "Ignored", on: varDecl) != nil {
            return property(.ignored)
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
