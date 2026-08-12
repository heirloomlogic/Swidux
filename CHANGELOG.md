# Changelog

Generated from [GitHub Releases](https://github.com/heirloomlogic/Swidux/releases) by
`.github/workflows/changelog.yml`. Edits here are overwritten on the next
release — write release notes on the release itself.

## [1.9.0](https://github.com/heirloomlogic/Swidux/releases/tag/1.9.0) — 2026-08-12

<!-- Release notes generated using configuration in .github/release.yml at main -->

### What's Changed
#### Added
* Macros: point the nested-type error at the property, not the expansion by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/70
* Persistence: merge the rows history says changed, not every row by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/78
* Persistence: read only the entities history says changed by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/81
#### Fixed
* Persistence: retry a failed flush instead of losing the write by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/62
* Undo: don't resurrect an entity another device deleted by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/63
* KeyValueStore: degrade on an unreachable Keychain instead of trapping by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/67
* Plugins: annotate every state slice with @Swidux so @Slice compiles by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/68
#### Other Changes
* Persistence: a diagnostic channel for what isn't a failure by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/66
* Persistence: an editing hold for the edit the store can't see by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/71
* Persistence: preserve the identity of a deleted row by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/76
* Persistence: read and merge only the rows that changed by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/77
* Persistence: generate the by-identifier descriptor too by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/82
* Sync: tell the observer which stores are its own by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/83
* Persistence: carry a withheld row forward instead of freezing the anchor by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/84
* Persistence: carry a withheld row forward on the mergeRemote path too by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/88
* Persistence: a seam that makes a fetch throw, and the cover it unblocks by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/89
* Persistence: count what a tick re-offered apart from what it merged by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/90
* Audit: fix two data-loss paths and harden the killswitch cache by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/91

**Full Changelog**: https://github.com/heirloomlogic/Swidux/compare/1.8.0...1.9.0

## [1.8.0](https://github.com/heirloomlogic/Swidux/releases/tag/1.8.0) — 2026-08-04

Fixes six hazards a [Fallow](https://heirloomlogic.com) audit traced to these packages rather than to the app, plus two latent bugs the audit didn't name. Most of it concerns what happens when a `rehydrate` or a sync tick overlaps a user who is still typing.

### Breaking

**`PersistenceCoordinator.rehydrate(into: inout State)` is gone.** Use `rehydrate(into: store, policy:)`.

The `inout` form could only be driven by packing a snapshot, awaiting, and unpacking — which clobbers every dispatch that lands during the awaits. That is the footgun itself, so it's replaced rather than documented around. The store-taking form runs every fetch first, then folds the result into a **freshly packed** snapshot in one suspension-free step. (The tutorial snippet that taught the old idiom didn't compile anyway: an escaping `@MainActor () async -> Void` can't capture `state` as `inout`.)

`hydrate(into: inout State)` **stays** — it runs before the store exists, so it has nothing to lose writes to.

**`SyncCoordinator.setSyncEnabled(_:into: inout State)` is gone.** Use `setSyncEnabled(_:into: store)`, and record the result with a normal dispatch afterward:

```swift
let status = await sync.setSyncEnabled(isOn, into: store)
store.send(.syncSettingsChanged(mode: sync.mode, status: status))
```

**`PersistableModel.swiduxFetchDescriptor(id:)` is gone**, and `@Persisted` no longer generates it. Its `fetchLimit = 1` is now actively wrong. `swiduxBatchFetchDescriptor(ids:)` is the only descriptor; the monomorphic-per-model construction stays, because the `-O` `#Predicate` miscompile it works around is still live.

**`rehydrate` now defaults to remote-wins.** Remote edits *and* deletions surface mid-session instead of waiting for relaunch — on a sync library, the old additive-only behaviour was a correctness bug on the primary use case. `MergePolicy.preferInMemory` restores the old contract per entity, for stores backing live text editors where a remote edit landing under the cursor is worse than a stale row.

### Added

**`Store.mutate(awaiting:merging:)`** — run async work, then fold the result into state without losing concurrent dispatches. `produce` receives no state, so it *cannot* hold one across an `await`; `merging` is synchronous, so nothing can land between the pack and the unpack. If you have ever written `var s = State(observer:)` / `await …` / `State.apply(s, to:)`, this replaces it.

**`fetchAll(of:)` and `snapshot(of:)`** on `PersistenceCoordinator` (and `EntityDB.fetchAll(of:)`) — read persisted rows without touching state, named by the entity you wrote rather than by its generated shadow model. Flushes pending writes first by default, so it can't return a row the user just edited away. Replaces the "rehydrate into a throwaway `AppState()`" idiom.

**An opt-in `collapse:` resolver** for reclaiming duplicate rows, plus `EntityCollapse.byID(preferring:)` and `PersistenceCoordinator.collapseDuplicates(into:)` for a "repair my data" action. The closure must be a pure function of *replicated* content — never `persistentModelID`, local timestamps, or array position — or two devices pick different survivors and tombstone each other's.

**`MergePolicy`** — `.preferRemote` (default), `.preferRemoteAdditive`, `.preferInMemory`, settable per coordinator, per entity, or per call.

### Fixed

**Duplicate-ID rows no longer lose writes.** CloudKit forbids unique constraints, so `@Persisted` emits none and two devices can legitimately end up holding two rows for one entity. `upsert` and `delete` previously acted on `.first` of the match: writes landed on an arbitrary row and deletes left survivors that resurrected the entity next launch. Now writes update **every** matching row, deletes remove **every** matching row, and reads collapse to one value per `id`. All order-independent and idempotent, so duplicates converge to identical content — which is why the framework still won't delete them for you without a `collapse:` closure.

**`EntityStore.init(_:)` corrupted its own index** when handed duplicate IDs: `positions` kept only the last index while `entities` kept every copy, so `count` over-reported and a later delete orphaned the earlier copy with no `positions` entry at all — a row visible in `values`, invisible to `contains`/subscript, undeletable, and re-flushed forever. `EntityDB.fetchAll` was feeding it duplicates.

**A drained-but-unflushed delete could be resurrected.** The [#44](https://github.com/heirloomlogic/Swidux/pull/44) guard reads `changes.deletions`, but `StateWriter.drain` has already cleared those — so once a delete reached the writer's buffers, the guard saw nothing and the merge re-added the row.

**Writes are no longer lost to a mid-flight rehydrate or sync toggle.** Three sources of local dirtiness are now unioned in the synchronous apply phase: `StateWriter.pendingIDs` (drained but unflushed), an `UnpersistedIDs` ledger (last flush attempt *failed* — previously nothing anywhere recorded that memory ≠ disk), and `EntityStore.changes`. An ID the local side still has something to say about always wins, and that guarantee is not configurable.

### Known limits

An **empty snapshot never removes anything** — zero rows can't be told from a store that is rebuilding, mid-import, or unreadable. So the last surviving entity can't be removed remotely until relaunch. This disappears in [#46](https://github.com/heirloomlogic/Swidux/issues/46)'s remaining half, where deletions come from tombstones rather than from inferred absence.

An **edit that hasn't been dispatched yet is invisible** to all of the above. Bindings made with `store.binding(_:sending:)` dispatch on write and are covered; a value sitting in a view's local `@State` is not ([#60](https://github.com/heirloomlogic/Swidux/issues/60)).

Also filed rather than silently dropped: [#58](https://github.com/heirloomlogic/Swidux/issues/58) (a failed flush is never retried), [#59](https://github.com/heirloomlogic/Swidux/issues/59) (undo after a remote deletion resurrects the entity), [#61](https://github.com/heirloomlogic/Swidux/issues/61) (structured diagnostics).

### Verification

`swift test` and `swift test -c release` (460 tests), `swift-format lint --strict`, and the Counter example build. The two-device scenario at the root of the audit was **not** exercised on real hardware; the deterministic in-process seam that forces a dispatch to land inside the read phase, plus disk-level duplicate assertions, stand in for it.

### What's Changed
* Upstream the Fallow persistence and sync hazards by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/56
* Tests: wait for the debounce timer instead of sleeping past it by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/57

**Full Changelog**: https://github.com/heirloomlogic/Swidux/compare/1.7.0...1.8.0

## [1.7.0](https://github.com/heirloomlogic/Swidux/releases/tag/1.7.0) — 2026-07-07

### What's Changed
* Independent production audit: core data-loss fixes, effect lifecycle, plugin hardening, CI + docs by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/42
* Fix rehydrate/merge resurrecting a locally-deleted entity by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/44

**Full Changelog**: https://github.com/heirloomlogic/Swidux/compare/1.6.0...1.7.0

## [1.6.0](https://github.com/heirloomlogic/Swidux/releases/tag/1.6.0) — 2026-07-01

### What's Changed
* Add ResilientPaywallService last-known-good entitlement decorator by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/41

**Full Changelog**: https://github.com/heirloomlogic/Swidux/compare/1.5.0...1.6.0

## [1.5.0](https://github.com/heirloomlogic/Swidux/releases/tag/1.5.0) — 2026-06-18

### What's Changed
* Document all plugins and both companion packages by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/39
* Feature flags: Keychain-backed bucketing identity + no-forever-flags governance by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/40

**Full Changelog**: https://github.com/heirloomlogic/Swidux/compare/1.4.0...1.5.0

## [1.4.0](https://github.com/heirloomlogic/Swidux/releases/tag/1.4.0) — 2026-06-11

### What's Changed
* Fix pre-release audit findings across core and all plugins by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/38

**Full Changelog**: https://github.com/heirloomlogic/Swidux/compare/1.3.0...1.4.0

## [1.3.0](https://github.com/heirloomlogic/Swidux/releases/tag/1.3.0) — 2026-06-10

### What's Changed
* Add first-class persistence: @Persisted macro + local and iCloud-sync plugins by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/34
* Make @Persisted CloudKit-safe: default values + optional relationships by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/35
* Gate Persnicket and swift-docc-plugin as dev-only tooling by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/36
* Fix @Persisted Release crash: generate monomorphic fetch descriptor by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/37

**Full Changelog**: https://github.com/heirloomlogic/Swidux/compare/1.2.0...1.3.0

## [1.2.0](https://github.com/heirloomlogic/Swidux/releases/tag/1.2.0) — 2026-05-29

### What's Changed
* Add generic Store with @SwiduxState macro for observation by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/10
* Fix killswitch plugin caching, failure fallback, and blocking enforcement by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/11
* Overhaul documentation: README, DocC, and agent skill by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/12
* Add CI workflows and document SwiduxRevenueCatPaywall companion by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/13
* Add testable UserDefaults support via KeyValueStore by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/14
* Rename macros: @SwiduxState → @Swidux, @SwiduxNested → Slice by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/15
* Add SwiduxAnalytics plugin with mapper, auto-identify, and DocC docs by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/16
* Add SwiduxFeatureFlags plugin (flags + A/B variants + remote-config) by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/17
* Add Store.binding(_:sending:) and externalize swidux-ref skill by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/18
* Re-fire identify on userProperties changes, not just userID transitions by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/19
* Add KeychainKeyValueStore adapter by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/20
* Document macOS sandbox entitlement & privacy guidance for Keychain store by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/21
* Add non-optional keypath init to AnalyticsIdentity by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/22
* Document service-result transition-observation convention (no plugin code change) by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/23
* Add vendor-free dev defaults for Analytics & Paywall by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/24
* Add Cloudflare Worker killswitch-config example + hosting docs by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/25
* Replace single-app KillswitchWorker with shared multi-app ConfigWorker by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/26
* Fix tiny .devPaywall sheet on macOS with 400x600 minimum by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/27
* Polish .devPaywall: header bar, entitlement toggles, less debugger feel by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/28
* Fix auto-identify ordering race in AnalyticsPlugin spawn by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/29
* Add URL(static:) to Swidux and migrate literal-URL sites by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/30
* Doc EntityStore.init(_:) as first-load only; point at merge for re-hydrate by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/31
* Document plugin call-site imports and @Swidux Swift-6-mode gotchas by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/32
* Add Swidux logo and README badges by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/33

**Full Changelog**: https://github.com/heirloomlogic/Swidux/compare/1.1.1...1.2.0

## [1.1.1](https://github.com/heirloomlogic/Swidux/releases/tag/1.1.1) — 2026-05-05

### What's Changed
* Fix DocC workflow for Swift 6.2 by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/9

**Full Changelog**: https://github.com/heirloomlogic/Swidux/compare/1.1.0...1.1.1

## [1.1.0](https://github.com/heirloomlogic/Swidux/releases/tag/1.1.0) — 2026-05-05

### What's Changed
* Simplify Effect to typealias, remove runEffect by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/1
* Refactor(swidux-ref skill): improve accuracy and completeness by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/2
* Add Counter demo app by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/3
* Add opt-in undo/redo middleware by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/4
* Untrack Package.resolved, clean up Package.swift, fix lint and build errors by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/5
* Remove vendored agent skills, relocate swidux-ref by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/6
* Add DocC documentation, simplify README by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/7
* Add unified plugin system with killswitch, parental gate, and paywall plugins by @heirloomlogic in https://github.com/heirloomlogic/Swidux/pull/8

### New Contributors
* @heirloomlogic made their first contribution in https://github.com/heirloomlogic/Swidux/pull/1

**Full Changelog**: https://github.com/heirloomlogic/Swidux/compare/1.0.0...1.1.0

## [1.0.0](https://github.com/heirloomlogic/Swidux/releases/tag/1.0.0) — 2026-02-16

**Full Changelog**: https://github.com/heirloomlogic/Swidux/commits/1.0.0
