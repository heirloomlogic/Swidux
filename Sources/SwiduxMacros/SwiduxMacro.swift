import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Generates an `@Observable` companion class and `SwiduxObservable` conformance for state structs.
public struct SwiduxMacro {}

extension SwiduxMacro: PeerMacro {
    /// Generates the `@Observable` observer class as a peer of the annotated struct.
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(
                Diagnostic(node: node, message: SwiduxDiagnostic.requiresStruct))
            return []
        }

        let properties = classifyProperties(of: structDecl)
        let accessLevel = structDecl.modifiers.first { modifier in
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.package), .keyword(.internal):
                return true
            default:
                return false
            }
        }?.name.text

        return [
            generateObserverClass(
                structName: structDecl.name.text,
                properties: properties,
                accessLevel: accessLevel
            )
        ]
    }
}

extension SwiduxMacro: ExtensionMacro {
    /// Generates the `SwiduxObservable` protocol conformance extension.
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

        let properties = classifyProperties(of: structDecl)
        return [
            generateConformanceExtension(
                structName: structDecl.name.text,
                properties: properties
            )
        ]
    }
}
