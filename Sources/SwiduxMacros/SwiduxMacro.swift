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

        let unsupported = unsupportedStructDiagnostics(
            of: structDecl, macro: "Swidux", allowsFileScopedAccess: context.lexicalContext.isEmpty)
        guard unsupported.isEmpty else {
            for diagnostic in unsupported { context.diagnose(diagnostic) }
            return []
        }

        diagnoseSkippedStoredProperties(of: structDecl, includesLetBindings: false, in: context)
        let properties = classifyProperties(of: structDecl)

        // Driven off the classified properties, not every member, so the
        // diagnostic covers exactly the types that reach the peer. A leaf's
        // default is copied into the observer's initializer; a slice's isn't.
        diagnoseUnqualifiedNestedTypes(
            of: structDecl,
            in: properties.map(\.typeSyntax),
            defaultValues: properties.filter { $0.kind == .leaf }.compactMap(\.defaultValue),
            generatedDeclaration: "observer class",
            in: context
        )

        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                varDecl.bindingSpecifier.tokenKind == .keyword(.let), !isTypeMember(varDecl)
            else { continue }
            for binding in varDecl.bindings where binding.initializer == nil {
                context.diagnose(Diagnostic(node: binding, message: SwiduxDiagnostic.letRequiresDefault))
            }
        }

        for property in properties where property.isMarkedSlice && property.kind != .nested {
            context.diagnose(
                Diagnostic(node: property.typeSyntax, message: SwiduxDiagnostic.sliceRequiresNamedType))
        }

        let accessLevel = observerAccessLevel(of: structDecl)

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
        // The peer expansion reports why an unsupported struct gets nothing.
        guard let structDecl = declaration.as(StructDeclSyntax.self),
            unsupportedStructDiagnostics(
                of: structDecl, macro: "Swidux", allowsFileScopedAccess: context.lexicalContext.isEmpty
            ).isEmpty
        else {
            return []
        }

        let properties = classifyProperties(of: structDecl)
        let accessLevel = observerAccessLevel(of: structDecl)
        return [
            generateConformanceExtension(
                typeName: type.trimmedDescription,
                properties: properties,
                keptLets: undefaultedLetNames(of: structDecl),
                accessLevel: accessLevel
            )
        ]
    }
}

/// The access keyword for the generated observer and conformance: the struct's
/// own, with a file-scope `private` spelled `fileprivate` (the same scope, but
/// `private` on a peer would hide it from the extension that uses it).
private func observerAccessLevel(of structDecl: StructDeclSyntax) -> String? {
    structDecl.modifiers.lazy.compactMap { modifier -> String? in
        switch modifier.name.tokenKind {
        case .keyword(.public), .keyword(.package), .keyword(.internal), .keyword(.fileprivate):
            return modifier.name.text
        case .keyword(.private):
            return "fileprivate"
        default:
            return nil
        }
    }.first
}
