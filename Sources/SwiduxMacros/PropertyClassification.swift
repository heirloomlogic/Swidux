import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Diagnoses stored properties the classifiers would silently skip — a missing
/// type annotation, a combined (multi-binding) or tuple-pattern declaration, or
/// a declaration inside `#if` — and `lazy` ones the generated code can't read.
/// A skipped property never reaches the generated observer/model, so its value
/// resets on every pack (or never persists) with no other signal; make it a
/// compile error.
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
        if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
            diagnoseStoredProperties(in: ifConfig, includesLetBindings: includesLetBindings, in: context)
            continue
        }
        // An initialized `let` is `@Persisted`'s to report, more precisely.
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
            isStoredInstanceProperty(varDecl, includesLetBindings: includesLetBindings),
            !(includesLetBindings && isInitializedLet(varDecl)),
            let first = varDecl.bindings.first
        else { continue }

        if varDecl.bindings.count > 1 {
            context.diagnose(
                Diagnostic(node: varDecl, message: SwiduxDiagnostic.singleBindingPerDeclaration))
            continue
        }
        if !first.pattern.is(IdentifierPatternSyntax.self) {
            context.diagnose(
                Diagnostic(node: first.pattern, message: SwiduxDiagnostic.requiresIdentifierPattern))
            continue
        }
        if isLazy(varDecl) {
            context.diagnose(Diagnostic(node: varDecl, message: SwiduxDiagnostic.lazyStoredProperty))
            continue
        }
        if first.typeAnnotation == nil {
            context.diagnose(
                Diagnostic(node: first, message: SwiduxDiagnostic.requiresTypeAnnotation))
        }
    }
}

/// Flags every stored property declared under `#if`, at any depth.
///
/// The classifiers see only the struct's direct members, and emitting the
/// property unconditionally would reference it in configurations where it
/// doesn't exist. Re-emitting matching `#if` blocks in the observer, model and
/// initializers is possible, but a pointed error is the smaller, safer fix.
///
/// Only members the macro would carry are flagged. Computed and type-level
/// ones never reach generated code, and neither does an optional `@Ignored`
/// property of `@Persisted` (the only caller that mirrors `let`s): it has no
/// column, and the memberwise initializer defaults it to `nil`, so being
/// invisible to the macro is exactly what it asks for.
private func diagnoseStoredProperties(
    in ifConfig: IfConfigDeclSyntax,
    includesLetBindings: Bool,
    in context: some MacroExpansionContext
) {
    for clause in ifConfig.clauses {
        guard case .decls(let members) = clause.elements else { continue }
        for member in members {
            if let nested = member.decl.as(IfConfigDeclSyntax.self) {
                diagnoseStoredProperties(in: nested, includesLetBindings: includesLetBindings, in: context)
            } else if let varDecl = member.decl.as(VariableDeclSyntax.self),
                isStoredInstanceProperty(varDecl, includesLetBindings: includesLetBindings)
            {
                if includesLetBindings, isMarkedIgnored(varDecl), let binding = varDecl.bindings.first {
                    // Same rule as an unconditional `@Ignored`: `toDomain()`
                    // must be able to leave it out and get `nil`.
                    if binding.typeAnnotation.flatMap({ optionalWrappedType(of: $0.type) }) == nil {
                        context.diagnose(
                            Diagnostic(node: binding, message: SwiduxDiagnostic.ignoredRequiresOptional))
                    }
                    continue
                }
                context.diagnose(
                    Diagnostic(node: varDecl, message: SwiduxDiagnostic.storedPropertyInIfConfig))
            }
        }
    }
}

/// Whether `varDecl` declares instance storage the caller's classifier is
/// responsible for: a `var` (or, for `@Persisted`, a `let`) that is neither
/// type-level nor computed.
private func isStoredInstanceProperty(_ varDecl: VariableDeclSyntax, includesLetBindings: Bool) -> Bool {
    let keyword = varDecl.bindingSpecifier.tokenKind
    guard keyword == .keyword(.var) || (includesLetBindings && keyword == .keyword(.let)),
        !isTypeMember(varDecl),
        let first = varDecl.bindings.first
    else { return false }
    return isStoredBinding(first)
}

/// The names of the struct's instance `let` properties that have no default.
///
/// `@Swidux` doesn't mirror `let`s, but every initializer it generates must
/// still initialize them. The restoring initializer keeps `current`'s value;
/// `init(observer:)` has no value to give them, so `@Swidux` diagnoses them
/// (`letRequiresDefault`). A `let` with a default is already initialized and
/// must not be assigned again.
func undefaultedLetNames(of structDecl: StructDeclSyntax) -> [String] {
    structDecl.memberBlock.members.flatMap { member -> [String] in
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
            varDecl.bindingSpecifier.tokenKind == .keyword(.let),
            !isTypeMember(varDecl)
        else { return [] }
        return varDecl.bindings.compactMap { binding in
            guard binding.initializer == nil else { return nil }
            return binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        }
    }
}

/// Whether a declaration carries `@Persisted`'s `@Ignored` marker.
private func isMarkedIgnored(_ varDecl: VariableDeclSyntax) -> Bool {
    varDecl.attributes.contains { attribute in
        guard case .attribute(let attr) = attribute else { return false }
        return attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Ignored"
    }
}

/// Whether a declaration is `lazy`. Both classifiers skip it, so the generated
/// code — which reads each property from an immutable value — never names it;
/// `diagnoseSkippedStoredProperties` reports it instead.
func isLazy(_ varDecl: VariableDeclSyntax) -> Bool {
    varDecl.modifiers.contains { $0.name.tokenKind == .keyword(.lazy) }
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
    /// Whether the property carries `@Slice`. Differs from `kind == .nested`
    /// only for a type `@Slice` can't nest, which is diagnosed and kept a leaf.
    let isMarkedSlice: Bool
    /// The access level the property spells, if any; the generated observer
    /// never republishes it wider. See `memberAccessPrefix`.
    let accessLevel: AccessLevel?

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
            !isLazy(varDecl),
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
            kind: hasNested && isDirectlyNamedType(typeSyntax) ? .nested : .leaf,
            defaultValue: defaultValue,
            isMarkedSlice: hasNested,
            accessLevel: AccessLevel(varDecl.modifiers)
        )
    }
}

/// Diagnostics for struct shapes neither macro can generate peers for: generic
/// parameters, which a separate peer declaration can't name, and `private`/
/// `fileprivate` access, where the peers must name the struct from outside it.
///
/// `allowsFileScopedAccess` exempts a `private`/`fileprivate` struct at file
/// scope, where both mean "this file" and the peers can simply be emitted
/// `fileprivate` beside it. `@Swidux` passes it for a top-level struct. A nested
/// `private` type is narrower than anything a peer can be declared with, and
/// `@Persisted`'s `@Model` class has never compiled at `fileprivate`.
///
/// Empty when the struct is supported. Callers emit no expansion otherwise, so
/// the error stands alone instead of arriving with a wall of failures reported
/// against generated code.
func unsupportedStructDiagnostics(
    of structDecl: StructDeclSyntax,
    macro: String,
    allowsFileScopedAccess: Bool = false
) -> [Diagnostic] {
    var diagnostics: [Diagnostic] = []
    if let generics = structDecl.genericParameterClause {
        diagnostics.append(Diagnostic(node: generics, message: SwiduxDiagnostic.genericStruct(macro: macro)))
    }
    if !allowsFileScopedAccess,
        let modifier = structDecl.modifiers.first(where: {
            $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)
        })
    {
        diagnostics.append(
            Diagnostic(node: modifier, message: SwiduxDiagnostic.restrictedAccessStruct(macro: macro)))
    }
    return diagnostics
}

/// Whether `type` names a type directly — `UIState` or `Feature.UIState` — so
/// appending `Observer` names its observer class. An optional, collection or
/// generic spelling has no such name.
func isDirectlyNamedType(_ type: TypeSyntax) -> Bool {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        return identifier.genericArgumentClause == nil
    }
    if let member = type.as(MemberTypeSyntax.self) {
        return member.genericArgumentClause == nil && isDirectlyNamedType(member.baseType)
    }
    return false
}
