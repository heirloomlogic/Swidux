# Troubleshooting

Symptoms you may hit while adopting Swidux, and what each one actually means.

## Xcode asks to "Trust & Enable" a macro

`@Swidux` and `@Persisted` are compiler plugins, so the first build in Xcode
prompts once per machine to trust the `SwiduxMacros` target. Approve it in the
build error's fix-it or under **Settings → Packages**. On CI, pass
`-skipMacroValidation` to `xcodebuild` instead — there's no one to click the
dialog.

## The first build is slow

Swidux depends on `swift-syntax`, which the macro system compiles from source
on first build (a few minutes on CI-class hardware). It's cached afterwards;
nothing is wrong. CI pipelines benefit from caching `.build/` or DerivedData.

## Console shows "Re-entrant Store.send(…) — deferring"

Something called `store.send` synchronously from inside a reducer or plugin
hook — usually a plugin observing state and dispatching in `afterReduce`, or a
`Binding` setter fired during view updates. The store defers the inner action
and runs it as a full cycle right after the current one, so state stays
consistent — but the fault log is telling you the design wants that follow-up
dispatched from an `Effect` instead.

## `call to main actor-isolated initializer … in a synchronous nonisolated context`

The module is compiling in Swift 5 language mode with
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. A `@Swidux nonisolated struct`
only gets a nonisolated synthesized memberwise initializer under **Swift 6
mode** (`SWIFT_VERSION = 6.0`); under Swift 5 mode the macro's state
reconstruction can't call it, and adding an explicit `nonisolated init` does
not rescue it. Switch the target to Swift 6 mode.

## Error: "stored properties need an explicit type annotation"

`var flag = false` gives the compiler an inferred type, but macros can't see
it — before this diagnostic existed, such a property was silently skipped and
its value reset on every dispatch. Write `var flag: Bool = false`. The same
applies to combined declarations: split `var a, b: Int` into separate
declarations.

## Keychain writes fail with OSStatus −34018 (`errSecMissingEntitlement`)

An unsigned local or CI build is using ``KeychainKeyValueStore`` without a
provisioning profile. This is a signing condition, not a prompt or a bug — the
data-protection keychain never prompts. Ship provisioning-profile-signed builds
with `accessGroup: nil`; for unsigned local/CI builds add a single
team-prefixed `keychain-access-groups` entitlement. Details in
<doc:KeyValueStoreGuide>.

## Contributors: the lint plugin doesn't run / dev tooling is missing

Dev tooling (the Persnoop linter, the DocC plugin) is gated behind a
gitignored `.dev-tooling` sentinel file so it never leaks into consumers'
dependency graphs. Create it at the package root — and if the package was
already built without it, run `swift package purge-cache` so SwiftPM re-reads
the manifest. See the repository's `CONTRIBUTING.md`.

## A `@Persisted` app crashes only in Release

If the crash is in fetching, make sure you're on ≥ 1.3.0: generic
`#Predicate` over a protocol-required keypath traps under `-O`, which is why
the macro generates a per-model `swiduxBatchFetchDescriptor`. Run
`swift test -c release` in CI to catch this class of issue — Debug builds and
default `swift test` pass.
