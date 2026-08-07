import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Diagnoses properties typed with one of the struct's *own* nested types spelled
/// by their bare name.
///
/// Both `@Swidux` and `@Persisted` are peer macros: the observer class and the
/// `@Model` shadow class are emitted alongside the annotated struct, at file
/// scope, with each property's type annotation copied verbatim. A nested name
/// resolves inside the struct body but not out there, so the compiler reports it
/// against the macro expansion buffer rather than the property the author wrote.
/// Naming the fix here is the whole point — the failure is otherwise a scavenger
/// hunt through generated source.
func diagnoseUnqualifiedNestedTypes(
    of structDecl: StructDeclSyntax,
    in propertyTypes: [TypeSyntax],
    generatedDeclaration: String,
    in context: some MacroExpansionContext
) {
    let nested = nestedTypeNames(of: structDecl)
    guard !nested.isEmpty else { return }
    let structName = structDecl.name.text

    let finder = UnqualifiedNestedTypeFinder(nestedTypeNames: nested)
    for type in propertyTypes {
        finder.walk(type)
    }

    for reference in finder.references {
        context.diagnose(
            Diagnostic(
                node: reference,
                message: SwiduxDiagnostic.unqualifiedNestedType(
                    name: reference.name.text,
                    enclosing: structName,
                    generatedDeclaration: generatedDeclaration
                )
            ))
    }
}

/// The names of the types `structDecl` declares in its own body. A nested
/// `typealias` is included: it fails to resolve at file scope exactly like a
/// nested `struct` does.
private func nestedTypeNames(of structDecl: StructDeclSyntax) -> Set<String> {
    // Matched kind by kind rather than through `NamedDeclSyntax`, which would also
    // pull in function and macro declarations and flag a property whose type
    // merely shares a name with one.
    Set(
        structDecl.memberBlock.members.compactMap { member -> String? in
            switch member.decl.as(DeclSyntaxEnum.self) {
            case .structDecl(let decl): return decl.name.text
            case .enumDecl(let decl): return decl.name.text
            case .classDecl(let decl): return decl.name.text
            case .actorDecl(let decl): return decl.name.text
            case .typeAliasDecl(let decl): return decl.name.text
            default: return nil
            }
        })
}

/// Collects bare references to the enclosing struct's nested types anywhere in a
/// type annotation.
///
/// Visiting only `IdentifierTypeSyntax` is what makes the wrapped cases fall out
/// for free. SwiftSyntax models `A.B` as a `MemberTypeSyntax` whose trailing `B`
/// is a plain token rather than an identifier-type node, so an already-qualified
/// `Outer.Inner` is never reached — while `Optional<T>`, `T?`, `[T]`, `[K: V]`,
/// `Set<T>`, tuples and function types all hold their element types as
/// identifier-type nodes and so are descended into. A `MemberTypeSyntax`'s *base*
/// is still visited, which correctly flags `Inner.Deeper` on `Inner`.
private final class UnqualifiedNestedTypeFinder: SyntaxVisitor {
    private let nestedTypeNames: Set<String>
    private(set) var references: [IdentifierTypeSyntax] = []

    init(nestedTypeNames: Set<String>) {
        self.nestedTypeNames = nestedTypeNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        if nestedTypeNames.contains(node.name.text) {
            references.append(node)
        }
        return .visitChildren
    }
}
