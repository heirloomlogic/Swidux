import SwiftSyntax
import SwiftSyntaxMacros

/// Marker macro for properties containing nested `@SwiduxState` structs.
public struct SwiduxNestedMacro: PeerMacro {
    /// Generates no peer declarations — serves only as a syntactic marker.
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
