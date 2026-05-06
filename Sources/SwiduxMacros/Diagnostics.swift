import SwiftDiagnostics

enum SwiduxStateDiagnostic: String, DiagnosticMessage {
    case requiresStruct

    var severity: DiagnosticSeverity { .error }

    var message: String {
        switch self {
        case .requiresStruct:
            return "@SwiduxState can only be applied to structs"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiduxMacros", id: rawValue)
    }
}
