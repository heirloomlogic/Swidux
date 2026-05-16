# Service-result reconcile: suppress redundant entitlement/verdict/config signals

Date: 2026-05-16
Status: Approved design (pre-implementation)
Scope: `SwiduxPaywall`, `SwiduxKillswitch`, `SwiduxFeatureFlags`

## Problem

Three plugins have a "service result received" action that fires on every
fetch/stream tick, not only when the value changed, and unconditionally
writes its payload into state:

- `PaywallPlugin` → `customerInfoUpdated(EntitlementSnapshot)`
  (`PaywallPlugin.swift:97`). Driven by the long-lived `observeCustomerInfo`
  stream **plus** `refreshCustomerInfo` (which `.dismiss` fires on every
  paywall close) **plus** `restorePurchases`. The `PaywallService` stream
  cadence is provider-controlled; the RevenueCat conformer emits a fresh
  `CustomerInfo` on every app foreground / SDK cache refresh / purchase, so
  the same `EntitlementSnapshot` is delivered many times per session.
- `KillswitchPlugin` → `verdictReceived(KillswitchVerdict)`
  (`KillswitchPlugin.swift:109`). Every `.fetch`/`.forceFetch` (cache hit or
  network) re-delivers a usually-identical verdict.
- `FeatureFlagsPlugin` → `refreshSucceeded(config, fetchedAt:)`
  (`FeatureFlagsPlugin.swift:83`). Every `.refresh` re-delivers a
  usually-identical config.

A downstream analytics mapping bound to one of these actions (observed:
`paywall_entitlement_snapshot` firing on every snapshot, mostly duplicates)
sees the real transition buried in stream noise.

Precedents already in the repo: `AnalyticsPlugin` diffs
`(userID, userProperties)` and only fires `identify` on change
(commit 74e0532); `FeatureFlagsPlugin.recordExposure`
(`FeatureFlagsPlugin.swift:110`) already uses the
`guard !already else { return nil }` "suppress redundant signal" idiom.

## Why a guard is required (not cosmetic)

Plugins mutate through `state: inout RootState` → `state[keyPath:]`. Per the
project finding (`memory/observable-findings.md`), the `inout`/`_modify`
path **bypasses `@Observable` equality checking**, so an unconditional
`state.x = incoming.x` propagates a write even when the value is identical.
An explicit "assign only on change" guard is the documented discipline that
finding prescribes.

It is doubly required for Killswitch: `verdictReceived` writes
`state.lastFetch = Date()` every poll (the cache-TTL gate read by `.fetch`),
so `KillswitchState` is never equal cycle-to-cycle. Whole-slice equality can
never suppress there; only writing `state.verdict` on real change yields a
clean verdict transition. Hence the comparison must be scoped to the
**meaningful field only** and must exclude bookkeeping fields.

## Approach (chosen: A — reducer reconciliation guard)

Unified rule, applied identically to all three service-result reducer cases:

> Always run the per-cycle bookkeeping writes. Compute `changed` by
> comparing only the incoming meaningful payload against the corresponding
> state field. Assign the meaningful field(s) only when `changed`. Single
> `return nil`.

Alternatives rejected: B (shared `reconcile` helper — abstracts only the
trivial comparison, not the differing bookkeeping; premature); C (split
bookkeeping and transition into two actions — adds permanent API surface and
an internal re-dispatch to solve what truthful state + the existing identity
diff already solve).

### PaywallPlugin — `case .customerInfoUpdated(let snapshot)`

```swift
case .customerInfoUpdated(let snapshot):
    // Bookkeeping: every stream tick / refresh / restore resolves loading and clears errors.
    state.isLoading = false
    state.error = nil
    // Reconcile entitlement only on real change so observers see one transition, not stream noise.
    let changed = snapshot.isPro != state.isPro
        || snapshot.hasPermanentLicense != state.hasPermanentLicense
    if changed {
        state.isPro = snapshot.isPro
        state.hasPermanentLicense = snapshot.hasPermanentLicense
    }
```

### KillswitchPlugin — `case .verdictReceived(let verdict)`

```swift
case .verdictReceived(let verdict):
    // Bookkeeping: advance the cache-TTL gate and clear errors on every poll, cache hit or network.
    state.lastFetch = Date()
    state.fetchError = nil
    // Reconcile verdict only on real change; lastFetch churns every poll and must not count as a change.
    if verdict != state.verdict {
        state.verdict = verdict
    }
```

### FeatureFlagsPlugin — `case .refreshSucceeded(let config, let fetchedAt)`

```swift
case .refreshSucceeded(let config, let fetchedAt):
    // Bookkeeping: record the fetch and resolve progress every refresh.
    state.lastFetchedAt = fetchedAt
    state.lastFetchError = nil
    state.isFetching = false
    // Reconcile config only on real change.
    if config != state.config {
        state.config = config
    }
```

All three keep the same "always bookkeep, then conditionally assign
meaningful field, single `return nil`" shape so the convention is visually
recognizable. All meaningful payload types are `Equatable`
(`EntitlementSnapshot`, `KillswitchVerdict`, `FeatureFlagsConfig`).

## Documented convention

Add a "Service-result actions and transition observation" subsection to
`Sources/Swidux/Documentation.docc/PluginArchitecture.md`, cross-referenced
from `PluginPaywallReference.md`, `PluginKillswitchReference.md`, and the
FeatureFlags reference. Update the `customerInfoUpdated` /
`verdictReceived` / `refreshSucceeded` action-semantics bullets to state the
reconcile-on-change behavior. Convention text:

> A service-result action fires on every fetch/stream tick, not only when
> the value changed. It always performs per-cycle bookkeeping (resolve
> loading, advance cache gates, clear errors) and reconciles its meaningful
> payload only on change. Derive analytics and side effects from the state
> slice transition, never from the raw service-result action. This mirrors
> how `AnalyticsPlugin` derives identity from state via `AnalyticsIdentity`,
> not from raw actions.

## Testing

Two tiers per plugin (no new test target).

Tier 1 — reducer behavior (existing `*PluginTests.swift` harness style):
- Transition: differing payload → meaningful field updated **and**
  bookkeeping applied.
- Redundant: identical payload → meaningful field still equals expected
  **and** bookkeeping demonstrably ran (Killswitch `lastFetch` strictly
  advances; Paywall `isLoading` `true→false`; FeatureFlags `isFetching`
  `true→false`).

Tier 2 — suppression regression guard (pins the `if changed` line; reducer
value assertions cannot, since the value is identical either way): host the
plugin in a real `Store` (`@Observable`, `PluginHost` — as in
`StoreTests.swift`), `withObservationTracking` on the meaningful slice
field; redundant `send` → tracking does not re-fire; genuine change `send`
→ it fires. One per plugin, same shape.

## Out of scope

- No `*Action` enum, `*Service` protocol, or factory changes. API surface
  unchanged.
- `recordExposure` unchanged (already correct; cited as precedent).
- No shared `reconcile` helper.
- `AnalyticsPlugin` untouched (identity diff already handles identify; this
  makes the state it derives from truthful).

## Downstream impact

The fix makes `isPro`/`hasPermanentLicense` / verdict / config transition
only on real change. A downstream event still bound to `customerInfoUpdated`
will still fire per-snapshot — Approach A does not change action cadence by
design. Actionable guidance for the consuming app: rebind such an event from
the action to the entitlement **state transition** (e.g. a diffed
people-property via `AnalyticsIdentity.userProperties`, re-evaluated and
diffed every dispatch since commit 74e0532). The new convention doc gives
the canonical pattern. The consuming session's two original "out of scope"
notes remain correctly scoped; nothing shipped there needs reverting.
