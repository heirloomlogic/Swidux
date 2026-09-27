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
        guard !isTypeMember(varDecl), let first = varDecl.bindings.first, isStoredBinding(first)
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

/// Whether a declaration is type-level (`static`/`class`) rather than instance
/// state. Neither macro mirrors it: the generated code reads every property
/// through an instance, and a static one isn't reachable that way.
func isTypeMember(_ varDecl: VariableDeclSyntax) -> Bool {
    varDecl.modifiers.contains { modifier in
        modifier.name.tokenKind == .keyword(.static) || modifier.name.tokenKind == .keyword(.class)
    }
}

/// Whether a binding stores its value: it has no accessor block, or one made up
/// only of `willSet`/`didSet` observers.
///
/// An observer doesn't make a property computed — it still has storage, so it
/// is state the macros must carry. A getter, explicit or shorthand, does.
/// Neither generated body needs the observers: the observer class and model
/// only hold the value, and packing assigns inside an `init`, where observers
/// don't fire.
func isStoredBinding(_ binding: PatternBindingSyntax) -> Bool {
    guard let accessorBlock = binding.accessorBlock else { return true }
    guard case .accessors(let accessors) = accessorBlock.accessors else { return false }
    return accessors.allSatisfy { accessor in
        accessor.accessorSpecifier.tokenKind == .keyword(.willSet)
            || accessor.accessorSpecifier.tokenKind == .keyword(.didSet)
    }
}

enum PropertyKind {
    case leaf
    case nested
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
        case .leaf:
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
            !isTypeMember(varDecl),
            let binding = varDecl.bindings.first,
            isStoredBinding(binding),
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
            let typeAnnotation = binding.typeAnnotation
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

        return ClassifiedProperty(
            name: name,
            typeSyntax: typeSyntax,
            kind: hasNested ? .nested : .leaf,
            defaultValue: defaultValue
        )
    }
}
