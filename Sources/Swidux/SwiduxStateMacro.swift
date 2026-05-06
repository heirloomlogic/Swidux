@attached(peer, names: suffixed(Observer))
@attached(extension, conformances: SwiduxObservable, names: arbitrary)
public macro SwiduxState() = #externalMacro(module: "SwiduxMacros", type: "SwiduxStateMacro")

@attached(peer)
public macro SwiduxNested() = #externalMacro(module: "SwiduxMacros", type: "SwiduxNestedMacro")
