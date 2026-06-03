import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SwiduxMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SwiduxMacro.self,
        SliceMacro.self,
        PersistedMacro.self,
        MarkerMacro.self,
    ]
}
