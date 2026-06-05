# Contributing to Swidux

## Enable dev tooling before your first build

Swidux is a published package, so its dev-only tooling — the
[Persnicket](https://github.com/HeirloomLogic/Persnicket) `swift-format` linter
(Persnoop) and the DocC command plugin — is **gated behind a gitignored
`.dev-tooling` sentinel** in `Package.swift`. This keeps Persnicket and
swift-docc-plugin out of downstream consumers' dependency graphs: a plain
checkout resolves only `swift-syntax`.

Maintainers opt in by creating the sentinel **once, before the first build**:

```sh
touch .dev-tooling
```

With the sentinel present, `swift build` resolves Persnicket and runs
`swift-format` lint as a pre-build step across every target — identically on the
command line, in Xcode, and in CI. Without it, your build mirrors a consumer's:
no Persnicket, no linting, no DocC plugin.

## If you built *before* creating the sentinel

SwiftPM caches the evaluated manifest keyed on `Package.swift`'s **text**. The
sentinel is an external file, so the manifest text is byte-identical whether or
not it exists — once SwiftPM has cached a consumer-mode evaluation, creating
`.dev-tooling` changes nothing until you clear that cache layer:

```sh
swift package purge-cache
swift package resolve
```

Note: `swift package reset` and Xcode's **Reset Package Caches** do **not** clear
this layer. `purge-cache` is the specific verb. (In Xcode: quit Xcode, run
`swift package purge-cache`, reopen `Package.swift`, then **File → Packages →
Resolve Package Versions** if stale dependencies linger.)

A fresh clone that runs `touch .dev-tooling` before its very first build avoids
all of this — the first and only manifest evaluation already sees the sentinel.

## Linting

CI runs `swift-format lint --strict` and fails on violations, so run the linter
locally before opening a PR. With the sentinel in place, Persnoop lints on every
`swift build`. To reformat in place, use the Persnipe command plugin:

```sh
swift package plugin --allow-writing-to-package-directory format-source-code
```
