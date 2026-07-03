import SwiftDiagnostics

enum SwiduxDiagnostic: String, DiagnosticMessage {
    case requiresStruct
    case persistedRequiresStruct
    case ignoredRequiresOptional
    case mirrorRequiresDefault
    case relationRequiresOptional
    case inlineRequiresDefault
    case requiresTypeAnnotation
    case singleBindingPerDeclaration

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
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiduxMacros", id: rawValue)
    }
}
