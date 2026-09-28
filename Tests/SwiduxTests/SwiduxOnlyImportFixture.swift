//
//  SwiduxOnlyImportFixture.swift
//  SwiduxTests
//
//  A `@Swidux` state in a file whose only import is `Swidux`, exactly as the
//  getting-started snippets write `AppState.swift`. The expansion uses
//  `@Observable`, and an expansion resolves names against the imports of the
//  file it expands in, so this file compiling is the assertion;
//  `SwiduxMacroCompiledTests` exercises the type at run time.
//

import Swidux

@Swidux
nonisolated struct SwiduxOnlyImportState: Equatable, Sendable {
    var count: Int = 0
}
