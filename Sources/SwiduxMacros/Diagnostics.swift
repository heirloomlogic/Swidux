import SwiftDiagnostics

enum SwiduxDiagnostic: String, DiagnosticMessage {
    case requiresStruct

    var severity: DiagnosticSeverity { .error }

    var message: String {
        switch self {
        case .requiresStruct:
            return "@Swidux can only be applied to structs"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiduxMacros", id: rawValue)
    }
}
