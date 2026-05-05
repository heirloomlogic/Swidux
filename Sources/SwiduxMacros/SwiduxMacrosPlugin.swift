import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SwiduxMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SwiduxStateMacro.self,
        SwiduxNestedMacro.self,
    ]
}
