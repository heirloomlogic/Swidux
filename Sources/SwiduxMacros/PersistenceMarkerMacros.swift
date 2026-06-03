import SwiftSyntax
import SwiftSyntaxMacros

/// Backs the `@Relation` / `@ForeignKey` / `@Inline` / `@Ignored` property
/// markers. They carry no behavior of their own — `@Persisted` reads them off
/// the property during classification — so a single no-op peer macro serves all
/// four declarations.
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
