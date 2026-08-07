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
data-protection keychain never prompts.

Nothing is persisted, but nothing crashes either: the write logs, returns
`false`, and the app continues. Ship provisioning-profile-signed builds with
`accessGroup: nil` to get real persistence.

Adding a team-prefixed `keychain-access-groups` entitlement also works, and is
the right call when you want the access group — but weigh it first, because it
makes the app require a provisioning profile for every signed build. It is
**not** a fix for a test host: `CODE_SIGNING_ALLOWED=NO` embeds no entitlements
at all, so there is nothing for the entitlement to attach to. Let the write
degrade there. Details in <doc:KeyValueStoreGuide>.

## `Test crashed with signal trap before establishing connection`

`xcodebuild test` dies before any test runs, naming nothing useful. If the app
mints a device identity or writes a token at launch, suspect the Keychain: the
test host is unsigned, the write fails, and a trap takes the process down before
the test bundle can attach.

Current versions degrade instead of trapping here, so upgrading Swidux is the
fix. To confirm the diagnosis on an older one, run the same scheme with
`CODE_SIGNING_ALLOWED=YES` — if it gets past launch, the Keychain was the cause.

## Edits disappear after a sync tick or an async load

Symptom: a keystroke, a toggle, or a whole entity vanishes — intermittently,
usually while something is loading or syncing, and never reproducibly.

The cause is almost always a hand-rolled bridge from `async` work into the
store. `Store` keeps state in an `@Observable` observer tree and converts to a
value-type snapshot on the way in and out ("pack" and "unpack"). If you pack a
snapshot, `await` something, and then unpack it, everything dispatched during
the `await` is silently overwritten:

```swift
var snapshot = AppState(observer: store.observer)   // ← packed BEFORE the await
await loadEverything(into: &snapshot)               // ← dispatches land here…
AppState.apply(snapshot, to: store.observer)        // ← …and are discarded here
```

`inout State` across a suspension point is the tell. The window is only as wide
as the `await`, which is why it presents as a rare glitch rather than a
reproducible bug.

Use ``Store/mutate(awaiting:merging:)`` instead. It runs the async work with no
access to state, then packs a *fresh* snapshot, merges, and unpacks in a single
step with no suspension point in between — so no dispatch can interleave:

```swift
await store.mutate {
    try await api.fetchItems()          // no state in scope; nothing to stale
} merging: { items, state in
    state.items.merge(from: EntityStore(items)) { _, _ in false }
}
```

The persistence stack's own async entry points already work this way — use
`persistence.rehydrate(into: store)` and `sync.setSyncEnabled(_:into: store)`,
not a snapshot you manage yourself. (`hydrate(into: &state)` is the exception,
and safe: it runs at launch, before the store exists.)

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
