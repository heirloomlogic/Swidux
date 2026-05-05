import SwiftSyntax
import SwiftSyntaxBuilder

func generateObserverClass(
    structName: String,
    properties: [ClassifiedProperty],
    accessLevel: String?
) -> DeclSyntax {
    let className = "\(structName)Observer"
    let accessPrefix = accessLevel.map { "\($0) " } ?? ""

    let memberLines = properties.map { prop -> String in
        let binding = prop.kind == .nested ? "let" : "var"
        return "    \(binding) \(prop.name): \(prop.observerTypeName)"
    }.joined(separator: "\n")

    let initParams = properties.map { prop -> String in
        let typeName = prop.observerTypeName
        if prop.kind == .nested {
            return "\(prop.name): \(typeName) = \(typeName)()"
        } else if let defaultValue = prop.defaultValue {
            return "\(prop.name): \(typeName) = \(defaultValue.trimmedDescription)"
        } else {
            return "\(prop.name): \(typeName)"
        }
    }.joined(separator: ", ")

    let initAssignments = properties.map { prop in
        "        self.\(prop.name) = \(prop.name)"
    }.joined(separator: "\n")

    let source = """
        @Observable
        @MainActor
        \(accessPrefix)final class \(className): @unchecked Sendable {
        \(memberLines)

            init(\(initParams)) {
        \(initAssignments)
            }
        }
        """

    return DeclSyntax(stringLiteral: source)
}
