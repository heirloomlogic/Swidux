// A macro expansion resolves names against the imports of the file it expands
// in, and `@Swidux` expands to an `@Observable` class. Re-exporting Observation
// makes `import Swidux` alone enough, as the getting-started snippets write it;
// without it that file gets "unknown attribute 'Observable'" reported against
// generated code. `Store` is itself built on Observation, so no client uses
// Swidux without it.
@_exported import Observation

@attached(peer, names: suffixed(Observer))
@attached(extension, conformances: SwiduxObservable, names: arbitrary)
public macro Swidux() = #externalMacro(module: "SwiduxMacros", type: "SwiduxMacro")

@attached(peer)
public macro Slice() = #externalMacro(module: "SwiduxMacros", type: "SliceMacro")
