import SwiftSyntax

enum PropertyKind {
    case leaf
    case nested
    case entityStore
}

struct ClassifiedProperty {
    let name: String
    let typeSyntax: TypeSyntax
    let kind: PropertyKind
    let defaultValue: ExprSyntax?

    var observerTypeName: String {
        switch kind {
        case .nested:
            return "\(baseTypeName)Observer"
        case .leaf, .entityStore:
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
            let binding = varDecl.bindings.first,
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
            let typeAnnotation = binding.typeAnnotation,
            binding.accessorBlock == nil
        else { return nil }

        let name = pattern.identifier.text
        let typeSyntax = typeAnnotation.type
        let defaultValue = binding.initializer?.value

        let hasNested = varDecl.attributes.contains { attr in
            guard case .attribute(let attrSyntax) = attr,
                let identifier = attrSyntax.attributeName.as(IdentifierTypeSyntax.self)
            else { return false }
            return identifier.name.text == "SwiduxNested"
        }

        let isEntityStore: Bool = {
            if let identifier = typeSyntax.as(IdentifierTypeSyntax.self) {
                return identifier.name.text == "EntityStore"
            }
            return false
        }()

        let kind: PropertyKind
        if hasNested {
            kind = .nested
        } else if isEntityStore {
            kind = .entityStore
        } else {
            kind = .leaf
        }

        return ClassifiedProperty(
            name: name,
            typeSyntax: typeSyntax,
            kind: kind,
            defaultValue: defaultValue
        )
    }
}
