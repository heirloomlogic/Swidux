import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Generates a SwiftData `@Model` shadow class and `PersistableEntity` /
/// `PersistableModel` conformances for a domain entity struct.
public struct PersistedMacro {}

extension PersistedMacro: PeerMacro {
    /// Emits the `{Type}Model` `@Model` class as a peer of the annotated struct.
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: node, message: SwiduxDiagnostic.persistedRequiresStruct))
            return []
        }

        let unsupported = unsupportedStructDiagnostics(of: structDecl, macro: "Persisted")
        guard unsupported.isEmpty else {
            for diagnostic in unsupported { context.diagnose(diagnostic) }
            return []
        }

        diagnoseSkippedStoredProperties(of: structDecl, includesLetBindings: true, in: context)
        diagnoseInitializedLets(of: structDecl, in: context)
        let properties = classifyPersistedProperties(of: structDecl)

        // The `@Model` shadow class is a peer outside the struct, where a bare
        // nested type name can't resolve. `@Ignored` is exempt: it emits no column
        // and no type reference, so its type never reaches that scope. Defaults are
        // copied into mirrored columns and `@Inline` getters.
        diagnoseUnqualifiedNestedTypes(
            of: structDecl,
            in: properties.filter { !isIgnored($0) }.map(\.typeSyntax),
            defaultValues: properties.filter { isMirror($0) || isInline($0) }.compactMap(\.defaultValue),
            generatedDeclaration: "model class",
            in: context
        )

        // Property-level diagnostics are anchored on the property, not on the
        // `@Persisted` attribute, so a struct with several offenders shows each.
        func diagnose(_ property: PersistedProperty, _ message: SwiduxDiagnostic) {
            context.diagnose(Diagnostic(node: property.binding, message: message))
        }

        for property in properties {
            // The model reads the property and rebuilds the struct through its
            // memberwise initializer, both from outside the struct.
            if let varDecl = property.binding.parent?.parent?.as(VariableDeclSyntax.self),
                varDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.private) && $0.detail == nil })
            {
                diagnose(property, .privatePersistedProperty)
            }

            switch property.kind {
            case .ignored:
                // `@Ignored` fields must be reconstructable as `nil` in `toDomain()`.
                if !property.isOptional { diagnose(property, .ignoredRequiresOptional) }
            case .mirror:
                // A non-optional, non-primitive mirrored attribute has no CloudKit-safe
                // default the macro can synthesize: require a default, optionality, or @Inline.
                if cloudKitMirrorDefault(for: property) == .missing { diagnose(property, .mirrorRequiresDefault) }
            case .association(let toMany, _, _):
                if !property.hasSupportedShape {
                    diagnose(property, .associationUnsupportedShape(toMany: toMany))
                } else if toMany && cloudKitMirrorDefault(for: property) == .missing {
                    diagnose(property, .mirrorRequiresDefault)
                }
                let column = "_swidux_\(property.name)Reference"
                if properties.contains(where: { $0.name == column && !isIgnored($0) }) {
                    diagnose(property, .associationColumnCollision(property: property.name, column: column))
                }
            case .inlineBlob:
                // A non-optional `@Inline` blob backed by `Data()` (the CloudKit-safe
                // column default) has nothing to decode until the first write; without
                // a domain default the getter cannot recover and would have to trap.
                if !property.isOptional && property.defaultValue == nil {
                    diagnose(property, .inlineRequiresDefault)
                }
                let column = "_swidux_\(property.name)Data"
                if properties.contains(where: { $0.name == column && !isIgnored($0) }) {
                    diagnose(property, .inlineColumnCollision(property: property.name, column: column))
                }
            }
        }

        return [
            generatePersistedModelClass(
                structName: structDecl.name.text,
                properties: properties.filter(\.hasSupportedShape),
                accessLevel: accessLevel(of: structDecl)
            )
        ]
    }
}

extension PersistedMacro: ExtensionMacro {
    /// Emits `extension <Struct>: PersistableEntity { typealias Model = ... }`.
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // The peer expansion reports why an unsupported struct gets nothing.
        guard let structDecl = declaration.as(StructDeclSyntax.self),
            unsupportedStructDiagnostics(of: structDecl, macro: "Persisted").isEmpty
        else {
            return []
        }
        return [
            generatePersistableEntityExtension(
                typeName: type.trimmedDescription,
                accessLevel: accessLevel(of: structDecl),
                properties: classifyPersistedProperties(of: structDecl).filter(\.hasSupportedShape)
            )
        ]
    }
}

// MARK: - Helpers

/// Diagnoses `let` properties with an initial value. Swift leaves them out of
/// the memberwise initializer, so `toDomain()` could never pass a stored value
/// back; the classifier skips them rather than emit a call that can't compile.
private func diagnoseInitializedLets(of structDecl: StructDeclSyntax, in context: some MacroExpansionContext) {
    for member in structDecl.memberBlock.members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self), !isTypeMember(varDecl),
            isInitializedLet(varDecl)
        else { continue }
        context.diagnose(Diagnostic(node: varDecl, message: SwiduxDiagnostic.initializedLetNotPersistable))
    }
}

private func isIgnored(_ property: PersistedProperty) -> Bool {
    if case .ignored = property.kind { return true }
    return false
}

private func isMirror(_ property: PersistedProperty) -> Bool {
    if case .mirror = property.kind { return true }
    return false
}

private func isInline(_ property: PersistedProperty) -> Bool {
    if case .inlineBlob = property.kind { return true }
    return false
}

private func accessLevel(of structDecl: StructDeclSyntax) -> String? {
    structDecl.modifiers.first { modifier in
        switch modifier.name.tokenKind {
        case .keyword(.public), .keyword(.package), .keyword(.internal):
            return true
        default:
            return false
        }
    }?.name.text
}
