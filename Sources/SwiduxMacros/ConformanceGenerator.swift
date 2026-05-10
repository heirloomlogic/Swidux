import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder

func generateConformanceExtension(
    structName: String,
    properties: [ClassifiedProperty],
    accessLevel: String?
) -> ExtensionDeclSyntax {
    let observerName = "\(structName)Observer"
    let accessPrefix = accessLevel.map { "\($0) " } ?? ""

    let initLines = properties.map { prop -> String in
        switch prop.kind {
        case .nested:
            return "        self.\(prop.name) = \(prop.baseTypeName)(observer: observer.\(prop.name))"
        case .leaf, .entityStore:
            return "        self.\(prop.name) = observer.\(prop.name)"
        }
    }.joined(separator: "\n")

    let makeArgs = properties.map { prop -> String in
        switch prop.kind {
        case .nested:
            return "            \(prop.name): \(prop.baseTypeName).makeObserver(from: state.\(prop.name))"
        case .leaf, .entityStore:
            return "            \(prop.name): state.\(prop.name)"
        }
    }.joined(separator: ",\n")

    let applyLines = properties.map { prop -> String in
        switch prop.kind {
        case .nested:
            return "        \(prop.baseTypeName).apply(snapshot.\(prop.name), to: observer.\(prop.name))"
        case .leaf, .entityStore:
            return "        observer.\(prop.name) = snapshot.\(prop.name)"
        }
    }.joined(separator: "\n")

    let restoreLines = properties.map { prop -> String in
        switch prop.kind {
        case .entityStore:
            return "        current.\(prop.name).restore(from: snapshot.\(prop.name))"
        case .nested:
            return "        \(prop.baseTypeName).applyRestore(from: snapshot.\(prop.name), to: &current.\(prop.name))"
        case .leaf:
            return "        current.\(prop.name) = snapshot.\(prop.name)"
        }
    }.joined(separator: "\n")

    let source = """
        extension \(structName): SwiduxObservable {
            \(accessPrefix)typealias Observer = \(observerName)

            @MainActor
            \(accessPrefix)init(observer: \(observerName)) {
        \(initLines)
            }

            @MainActor
            \(accessPrefix)static func makeObserver(from state: \(structName)) -> \(observerName) {
                \(observerName)(
        \(makeArgs)
                )
            }

            @MainActor
            \(accessPrefix)static func apply(_ snapshot: \(structName), to observer: \(observerName)) {
        \(applyLines)
            }

            @MainActor
            \(accessPrefix)static func applyRestore(from snapshot: \(structName), to current: inout \(structName)) {
        \(restoreLines)
            }
        }
        """

    let sourceFile = Parser.parse(source: source)
    // swiftlint:disable:next force_unwrapping
    guard let firstStatement = sourceFile.statements.first else {
        fatalError("Failed to parse generated SwiduxObservable extension")
    }
    return firstStatement.item.cast(ExtensionDeclSyntax.self)
}
