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

        let properties = classifyPersistedProperties(of: structDecl)

        // `@Ignored` fields must be reconstructable as `nil` in `toDomain()`.
        for property in properties where isIgnored(property) && !property.isOptional {
            context.diagnose(Diagnostic(node: node, message: SwiduxDiagnostic.ignoredRequiresOptional))
        }

        return [
            generatePersistedModelClass(
                structName: structDecl.name.text,
                properties: properties,
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
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            return []
        }
        return [
            generatePersistableEntityExtension(
                structName: structDecl.name.text,
                accessLevel: accessLevel(of: structDecl)
            )
        ]
    }
}

// MARK: - Helpers

private func isIgnored(_ property: PersistedProperty) -> Bool {
    if case .ignored = property.kind { return true }
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
