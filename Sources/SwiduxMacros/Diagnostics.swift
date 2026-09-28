import SwiftDiagnostics

enum SwiduxDiagnostic: DiagnosticMessage {
    case requiresStruct
    case persistedRequiresStruct
    case ignoredRequiresOptional
    case mirrorRequiresDefault
    case relationRequiresOptional
    case inlineRequiresDefault
    case requiresTypeAnnotation
    case singleBindingPerDeclaration
    case unqualifiedNestedType(name: String, enclosing: String, generatedDeclaration: String)
    case storedPropertyInIfConfig
    case requiresIdentifierPattern
    case lazyStoredProperty
    case initializedLetNotPersistable
    case privatePersistedProperty
    case genericStruct(macro: String)
    case restrictedAccessStruct(macro: String)
    case sliceRequiresNamedType
    case selfInDefaultValue(enclosing: String, generatedDeclaration: String)
    case relationInverseUnsupported
    case relationUnsupportedShape
    case inlineColumnCollision(property: String, column: String)
    case letRequiresDefault

    var severity: DiagnosticSeverity { .error }

    var message: String {
        switch self {
        case .requiresStruct:
            return "@Swidux can only be applied to structs"
        case .persistedRequiresStruct:
            return "@Persisted can only be applied to structs"
        case .ignoredRequiresOptional:
            return "@Ignored properties must be optional so they can be reconstructed as nil when loading from storage"
        case .mirrorRequiresDefault:
            return
                "Persisted properties of a non-primitive type must provide a default value (= …), be optional, or be marked @Inline to be CloudKit-safe"
        case .relationRequiresOptional:
            return
                "@Relation to-one properties must be optional (T?) or to-many to be CloudKit-safe; CloudKit forbids non-optional relationships"
        case .inlineRequiresDefault:
            return
                "Non-optional @Inline properties must provide a default value (= …) or be optional, so a missing or undecodable blob can be recovered instead of crashing"
        case .requiresTypeAnnotation:
            return
                "Stored properties need an explicit type annotation (var name: Type = …); a property with an inferred type is invisible to the macro, so its value would silently reset instead of being observed/persisted"
        case .singleBindingPerDeclaration:
            return
                "Declare each stored property separately (var a: Int; var b: Int); only the first binding of a combined declaration is visible to the macro, so the rest would silently reset instead of being observed/persisted"
        case .unqualifiedNestedType(let name, let enclosing, let generatedDeclaration):
            return
                "Nested type '\(name)' must be written with its qualified name '\(enclosing).\(name)'; the generated \(generatedDeclaration) is emitted as a peer outside the struct, where the bare name doesn't resolve"
        case .storedPropertyInIfConfig:
            return
                "Stored properties inside #if are not supported; they are invisible to the macro, so their values would silently reset instead of being observed/persisted. Declare the property unconditionally and move the #if into its type or value"
        case .requiresIdentifierPattern:
            return
                "Declare each stored property with a plain name (var a: Int); a tuple-pattern property is invisible to the macro, so its values would silently reset instead of being observed/persisted"
        case .lazyStoredProperty:
            return
                "lazy stored properties are not supported; the generated code reads every stored property from an immutable value, which can't run a lazy initializer. Store the value eagerly or make it computed"
        case .initializedLetNotPersistable:
            return
                "A let with an initial value can't be persisted: the memberwise initializer has no parameter for it, so the generated model can't load it. Make it a var, or static if it is a constant"
        case .privatePersistedProperty:
            return
                "@Persisted can't mirror a private property; the generated model reads and rebuilds it from outside the struct. Make it fileprivate or wider, or mark it @Ignored"
        case .genericStruct(let macro):
            return
                "@\(macro) can't be applied to a generic struct; the generated peer is a separate declaration that can't name the struct's generic parameters"
                + (macro == "Swidux" ? ". Hand-write the SwiduxObservable conformance instead" : "")
        case .restrictedAccessStruct(let macro):
            return
                "@\(macro) can't be applied to a private or fileprivate struct; the generated peer declarations must name its type from outside it. Make the struct internal or wider"
        case .sliceRequiresNamedType:
            return
                "@Slice requires the property's type to name a @Swidux struct directly (UIState or Feature.UIState), not an optional, collection, or generic type"
        case .selfInDefaultValue(let enclosing, let generatedDeclaration):
            return
                "'Self' in a property's type or default value must be written as '\(enclosing)'; the generated \(generatedDeclaration) is emitted outside the struct, where Self doesn't refer to it"
        case .relationInverseUnsupported:
            return
                "@Relation(inverse:) is not supported: a @Relation is an owned value composition, and a domain value can't hold a back-reference to its parent without containing itself. Remove inverse:, and keep the parent's id in a @ForeignKey property if the child needs it"
        case .relationUnsupportedShape:
            return
                "@Relation properties must be declared as [T] (to-many) or T? (to-one), where T names a @Persisted struct directly"
        case .inlineColumnCollision(let property, let column):
            return
                "@Inline property '\(property)' stores its blob in a generated '\(column)' column, which collides with the property '\(column)'; rename one of them"
        case .letRequiresDefault:
            return
                "A let without a default can't be rebuilt by the generated init(observer:), which reads only the var properties the observer mirrors; give it a default, or make it a var"
        }
    }

    /// Stable per-case identifier. Spelled out rather than derived from a raw
    /// value so the cases with associated values can carry what their messages need.
    private var id: String {
        switch self {
        case .requiresStruct: return "requiresStruct"
        case .persistedRequiresStruct: return "persistedRequiresStruct"
        case .ignoredRequiresOptional: return "ignoredRequiresOptional"
        case .mirrorRequiresDefault: return "mirrorRequiresDefault"
        case .relationRequiresOptional: return "relationRequiresOptional"
        case .inlineRequiresDefault: return "inlineRequiresDefault"
        case .requiresTypeAnnotation: return "requiresTypeAnnotation"
        case .singleBindingPerDeclaration: return "singleBindingPerDeclaration"
        case .unqualifiedNestedType: return "unqualifiedNestedType"
        case .storedPropertyInIfConfig: return "storedPropertyInIfConfig"
        case .requiresIdentifierPattern: return "requiresIdentifierPattern"
        case .lazyStoredProperty: return "lazyStoredProperty"
        case .initializedLetNotPersistable: return "initializedLetNotPersistable"
        case .privatePersistedProperty: return "privatePersistedProperty"
        case .genericStruct: return "genericStruct"
        case .restrictedAccessStruct: return "restrictedAccessStruct"
        case .sliceRequiresNamedType: return "sliceRequiresNamedType"
        case .selfInDefaultValue: return "selfInDefaultValue"
        case .relationInverseUnsupported: return "relationInverseUnsupported"
        case .relationUnsupportedShape: return "relationUnsupportedShape"
        case .inlineColumnCollision: return "inlineColumnCollision"
        case .letRequiresDefault: return "letRequiresDefault"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiduxMacros", id: id)
    }
}
