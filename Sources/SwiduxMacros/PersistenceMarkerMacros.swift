import SwiftSyntax
import SwiftSyntaxMacros

/// Backs the persistence property markers. They carry no behavior of their own;
/// `@Persisted` reads them during classification, so one no-op peer macro serves
/// every declaration.
public struct MarkerMacro: PeerMacro {
    /// Emits no peers — the marker carries metadata read by ``@Persisted``.
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
