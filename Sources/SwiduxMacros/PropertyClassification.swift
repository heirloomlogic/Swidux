import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Diagnoses stored properties the classifiers would silently skip — a missing
/// type annotation or a combined (multi-binding) declaration. A skipped
/// property never reaches the generated observer/model, so its value resets on
/// every pack (or never persists) with no other signal; make it a compile error.
///
/// `includesLetBindings` matches the caller's classifier: `@Persisted` mirrors
/// `let` properties, `@Swidux` does not (an unmutable leaf can't lose state —
/// and a `let` without a default already fails the generated initializer).
func diagnoseSkippedStoredProperties(
    of structDecl: StructDeclSyntax,
    includesLetBindings: Bool,
    in context: some MacroExpansionContext
) {
    for member in structDecl.memberBlock.members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
        let keyword = varDecl.bindingSpecifier.tokenKind
        guard keyword == .keyword(.var) || (includesLetBindings && keyword == .keyword(.let))
        else { continue }
        // Type-level members aren't instance state; computed properties
        // (accessor block on the first binding) aren't stored.
        let isStatic = varDecl.modifiers.contains { modifier in
            modifier.name.tokenKind == .keyword(.static)
                || modifier.name.tokenKind == .keyword(.class)
        }
        guard !isStatic, let first = varDecl.bindings.first, first.accessorBlock == nil
        else { continue }

        if varDecl.bindings.count > 1 {
            context.diagnose(
                Diagnostic(node: varDecl, message: SwiduxDiagnostic.singleBindingPerDeclaration))
            continue
        }
        if first.typeAnnotation == nil {
            context.diagnose(
                Diagnostic(node: first, message: SwiduxDiagnostic.requiresTypeAnnotation))
        }
    }
}

enum PropertyKind {
    case leaf
    case nested
    case entityStore
}

struct ClassifiedProperty {
    let name: String
    let typeSyntax: TypeSyntax
    let kind: PropertyKind
    let defaultValue: ExprSyntax?

    var observerTypeName: String {
        switch kind {
        case .nested:
            return "\(baseTypeName)Observer"
        case .leaf, .entityStore:
            return typeSyntax.trimmedDescription
        }
    }

    var baseTypeName: String {
        if let identifier = typeSyntax.as(IdentifierTypeSyntax.self) {
            return identifier.name.text
        }
        return typeSyntax.trimmedDescription
    }
}

func classifyProperties(of structDecl: StructDeclSyntax) -> [ClassifiedProperty] {
    structDecl.memberBlock.members.compactMap { member -> ClassifiedProperty? in
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
            varDecl.bindingSpecifier.tokenKind == .keyword(.var),
            let binding = varDecl.bindings.first,
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
            let typeAnnotation = binding.typeAnnotation,
            binding.accessorBlock == nil
        else { return nil }

        let name = pattern.identifier.text
        let typeSyntax = typeAnnotation.type
        let defaultValue = binding.initializer?.value

        let hasNested = varDecl.attributes.contains { attr in
            guard case .attribute(let attrSyntax) = attr,
                let identifier = attrSyntax.attributeName.as(IdentifierTypeSyntax.self)
            else { return false }
            return identifier.name.text == "Slice"
        }

        let isEntityStore: Bool = {
            if let identifier = typeSyntax.as(IdentifierTypeSyntax.self) {
                return identifier.name.text == "EntityStore"
            }
            return false
        }()

        let kind: PropertyKind
        if hasNested {
            kind = .nested
        } else if isEntityStore {
            kind = .entityStore
        } else {
            kind = .leaf
        }

        return ClassifiedProperty(
            name: name,
            typeSyntax: typeSyntax,
            kind: kind,
            defaultValue: defaultValue
        )
    }
}
