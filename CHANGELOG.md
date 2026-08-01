# Changelog

Generated from [GitHub Releases](https://github.com/heirloomlogic/Swidux/releases) by
`.github/workflows/changelog.yml`. Edits here are overwritten on the next
release — write release notes on the release itself.

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
