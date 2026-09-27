import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder

/// `typeName` is the extended type as the compiler names it — qualified when the
/// struct is nested (`Feature.State`) — and the observer peer, declared beside the
/// struct, is named by appending `Observer` to it (`Feature.StateObserver`).
func generateConformanceExtension(
    typeName: String,
    properties: [ClassifiedProperty],
    keptLets: [String] = [],
    accessLevel: String?
) -> ExtensionDeclSyntax {
    let observerName = "\(typeName)Observer"
    let accessPrefix = accessLevel.map { "\($0) " } ?? ""

    let initLines = properties.map { prop -> String in
        switch prop.kind {
        case .nested:
            return "        self.\(prop.name) = \(prop.baseTypeName)(observer: observer.\(prop.name))"
        case .leaf:
            return "        self.\(prop.name) = observer.\(prop.name)"
        }
    }.joined(separator: "\n")

    let makeArgs = properties.map { prop -> String in
        switch prop.kind {
        case .nested:
            return "            \(prop.name): \(prop.baseTypeName).makeObserver(from: state.\(prop.name))"
        case .leaf:
            return "            \(prop.name): state.\(prop.name)"
        }
    }.joined(separator: ",\n")

    let applyLines = properties.map { prop -> String in
        switch prop.kind {
        case .nested:
            return "        \(prop.baseTypeName).apply(snapshot.\(prop.name), to: observer.\(prop.name))"
        case .leaf:
            return "        observer.\(prop.name) = snapshot.\(prop.name)"
        }
    }.joined(separator: "\n")

    // One call for every kind. Whether a property is an entity store, a nested
    // state that may opt out of undo, or a plain value is a question about its
    // resolved type, which the syntax can't answer (`typealias Cards =
    // EntityStore<Card>`); `SwiduxRestore`'s overloads answer it.
    //
    // The restored value is built in an initializer, where assigning a stored
    // property doesn't run its `willSet`/`didSet`. Mutating `current` in place
    // (or passing its properties `inout`) would run every observer in the tree
    // on each undo, and an observer that touches a sibling — `didSet {
    // revision += 1 }` — would leave the restored state unequal to its snapshot.
    //
    // It must initialize every stored property, not only the mirrored ones: a
    // `let` without a default (diagnosed, since `init(observer:)` can't set
    // it) keeps `current`'s value, and a `let` with one is already set.
    let restoreLines =
        (properties.map { prop -> String in
            "        self.\(prop.name) = SwiduxRestore.restored(current.\(prop.name), from: snapshot.\(prop.name))"
        } + keptLets.map { "        self.\($0) = current.\($0)" }).joined(separator: "\n")

    let source = """
        extension \(typeName): SwiduxObservable {
            \(accessPrefix)typealias Observer = \(observerName)

            @MainActor
            \(accessPrefix)init(observer: \(observerName)) {
        \(initLines)
            }

            @MainActor
            \(accessPrefix)static func makeObserver(from state: \(typeName)) -> \(observerName) {
                \(observerName)(
        \(makeArgs)
                )
            }

            @MainActor
            \(accessPrefix)static func apply(_ snapshot: \(typeName), to observer: \(observerName)) {
        \(applyLines)
            }

            @MainActor
            \(accessPrefix)static func applyRestore(from snapshot: \(typeName), to current: inout \(typeName)) {
                current = \(typeName)(swiduxRestoring: current, from: snapshot)
            }

            @MainActor
            private init(swiduxRestoring current: \(typeName), from snapshot: \(typeName)) {
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
