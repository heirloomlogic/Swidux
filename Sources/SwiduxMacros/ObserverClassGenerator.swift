import SwiftSyntax
import SwiftSyntaxBuilder

func generateObserverClass(
    structName: String,
    properties: [ClassifiedProperty],
    accessLevel: String?
) -> DeclSyntax {
    let className = "\(structName)Observer"
    let accessPrefix = accessLevel.map { "\($0) " } ?? ""
    let requiresSeparatedInitializers = accessLevel == "public" || accessLevel == "package"

    let memberLines = properties.map { prop -> String in
        let binding = prop.kind == .nested ? "let" : "var"
        let access = memberAccessPrefix(structAccess: accessLevel, member: prop.accessLevel)
        return "    \(access)\(binding) \(prop.name): \(prop.observerTypeName)"
    }.joined(separator: "\n")

    let memberwiseParams = properties.map { prop -> String in
        let typeName = prop.observerTypeName
        if requiresSeparatedInitializers {
            return "\(prop.name): \(typeName)"
        } else if prop.kind == .nested {
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

    let memberwiseAccess = initializerAccessPrefix(
        structAccess: accessLevel,
        members: properties.map(\.accessLevel)
    )
    let memberwiseInitializer = """
            \(memberwiseAccess)init(\(memberwiseParams)) {
        \(initAssignments)
            }
        """

    let defaultAssignments = properties.compactMap { prop -> String? in
        let value =
            prop.kind == .nested
            ? "\(prop.observerTypeName)()"
            : prop.defaultValue?.trimmedDescription
        return value.map { "        self.\(prop.name) = \($0)" }
    }
    let defaultInitializer: String? =
        requiresSeparatedInitializers && defaultAssignments.count == properties.count
        ? """
            \(accessPrefix)init() {
        \(defaultAssignments.joined(separator: "\n"))
            }
        """
        : nil
    let initializers = [defaultInitializer, properties.isEmpty ? nil : memberwiseInitializer]
        .compactMap { $0 }
        .joined(separator: "\n\n")

    let source = """
        @Observable
        @MainActor
        \(accessPrefix)final class \(className): @unchecked Sendable {
        \(memberLines)

        \(initializers)
        }
        """

    return DeclSyntax(stringLiteral: source)
}
