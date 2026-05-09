@attached(peer, names: suffixed(Observer))
@attached(extension, conformances: SwiduxObservable, names: arbitrary)
public macro Swidux() = #externalMacro(module: "SwiduxMacros", type: "SwiduxMacro")

@attached(peer)
public macro Slice() = #externalMacro(module: "SwiduxMacros", type: "SliceMacro")
