import SwiftDiagnostics

enum SwiduxDiagnostic: String, DiagnosticMessage {
    case requiresStruct
    case persistedRequiresStruct
    case ignoredRequiresOptional
    case mirrorRequiresDefault
    case relationRequiresOptional

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
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiduxMacros", id: rawValue)
    }
}
