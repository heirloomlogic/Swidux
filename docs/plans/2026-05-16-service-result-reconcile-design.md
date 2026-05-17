# Service-result reconcile: suppress redundant entitlement/verdict/config signals

Date: 2026-05-16
Status: **Superseded by Revision 2 — documentation-only outcome, no plugin code change**
Scope: **no plugin code change**; documented convention: all three

## Revision 2 (2026-05-16) — no code change; the guard is inert for all three

Execution-time verification falsified the technical premise of Approach A
(and of Revision 1's "Approach A works for Paywall"). The "revert the guard
and watch the Tier 2 test fail" step showed the test *still passed* without
the guard.

Mechanism: `Store.send` does **not** mutate the observed property through
`inout`. It packs `var state = State(observer: observer)`, the plugin
mutates that **local struct copy**, then `State.apply(state, to: observer)`
writes back. The generated `apply` for a leaf slice
(`ConformanceGenerator.swift:36`) is a **plain assignment**
`observer.paywall = snapshot.paywall`, and `@Observable`'s synthesized
setter **equality-gates `Equatable` values** (see [[observable-findings]],
Experiment 1 / root cause #1). So a redundant cycle leaves the local struct
equal → `apply` assigns an equal value → `@Observable` suppresses the
notification, **with or without any reducer guard**.

The "`inout` bypasses `@Observable` equality" rationale describes
Experiment 2 (a Store that does `reduce(state: &observedProperty)`
directly). Swidux deliberately does not do that — it uses pack/unpack +
plain-assignment `apply` (Experiment 3; the memory concluded "equality
guards can be removed"). Therefore the reducer reconcile guard is inert for
**Paywall, Killswitch, and FeatureFlags alike** — Paywall is not special.

State observation is already deduplicated by the Store before any change.
The downstream's `paywall_entitlement_snapshot`-on-every-snapshot is caused
by mapping the **action** (whose cadence no guard changes), not state.

**Decision (supersedes Revision 1): no plugin code change to any of the
three. The fix is the documented convention only. A Store-level
`@Observable`/`apply` suppression regression test is kept (it pins Store
behavior, not a plugin guard).**

## Revision 1 (2026-05-16) — scope narrowed to Paywall *(superseded by Revision 2)*

The initial design applied Approach A to all three plugins. Tracing how
observation actually works (`SwiduxObservable` / `Store.apply`, precedent in
`StoreBindingTests`) showed the observer tree holds each plugin slice as a
single observed property — granularity is per-slice, not per-field.

`KillswitchPlugin.verdictReceived` writes `state.lastFetch = Date()` every
poll, and `FeatureFlagsPlugin.refreshSucceeded` writes
`state.lastFetchedAt = fetchedAt` every refresh (both mandatory bookkeeping).
So `KillswitchState`/`FeatureFlagsState` is never equal cycle-to-cycle
regardless of a verdict/config guard: `Store.apply` reassigns the slice and
the slice notifies on every poll anyway. Meanwhile a value-diffing consumer
(the recommended `AnalyticsIdentity.userProperties` path) already sees the
verdict/config payload as `==` on a no-op cycle, with or without a guard.

Therefore a reconcile guard in Killswitch/FeatureFlags has **no observable
effect** under the current state shape and its suppression test cannot be
written. Approach A has real effect **only for Paywall's stream path**, where
a no-op cycle leaves `PaywallState` fully equal yet the `inout` write still
notifies. Killswitch/FeatureFlags need no code change — their payload is
already diff-stable on no-op, so the documented consume-by-value-diff
convention gives them clean transitions for free.

**Decision: code change = Paywall only. Convention doc = all three.**

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

## Why a guard is required (not cosmetic) *(WRONG — superseded by Revision 2)*

> This section's premise is false for the Swidux `Store`. Retained only to
> document the reasoning that the execution-time verification falsified. See
> Revision 2: `Store.send` mutates a local struct copy, not the observed
> property; `State.apply`'s plain assignment is `@Observable`
> equality-gated, so no reducer guard is required or effective.

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

## Approach (chosen: A — reducer reconciliation guard) *(NOT IMPLEMENTED — superseded by Revision 2)*

> No reducer guard was shipped. The guard is inert under the Swidux Store
> (see Revision 2). The sections below are the original proposal, retained
> for the decision trail only.

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

### KillswitchPlugin / FeatureFlagsPlugin — no code change

Per the revision above, a reconcile guard in `verdictReceived` /
`refreshSucceeded` has no observable effect (the per-poll
`lastFetch`/`lastFetchedAt` write churns the whole slice regardless, and the
verdict/config payload is already `==` on a no-op cycle for value-diffing
consumers). They are covered by the documented convention only.

## Documented convention

This is the **entire fix** (Revision 2). Add a "Service-result actions and
transition observation" subsection to
`Sources/Swidux/Documentation.docc/PluginArchitecture.md`, cross-referenced
from `PluginPaywallReference.md`, `PluginKillswitchReference.md`, and the
FeatureFlags reference. Convention text:

> A service-result action (`customerInfoUpdated`, `verdictReceived`,
> `refreshSucceeded`) fires on **every** fetch/stream tick, not only when
> the value changed, and unconditionally writes its payload. Do **not** map
> analytics or side effects to the raw action — it fires duplicates by
> design. Observe the **state slice** (or a value derived from it) instead:
> the Swidux `Store` packs state, lets reducers mutate a copy, then writes
> back via `State.apply`, whose plain assignment is `@Observable`
> equality-gated — so a slice whose value did not change emits no
> notification, and a value-diffing consumer (`AnalyticsIdentity.userProperties`,
> which `AnalyticsPlugin` re-evaluates and diffs every dispatch) sees
> exactly the real transitions. This dedup is a property of the Store, not
> of any per-plugin guard.

## Testing (Paywall only)

Two tiers in `Tests/SwiduxPaywallTests/PaywallPluginTests.swift` (no new
test target).

Tier 1 — reducer behavior (existing harness style):
- Transition: a `customerInfoUpdated` snapshot whose entitlement differs from
  current → `isPro`/`hasPermanentLicense` updated **and** bookkeeping applied
  (`isLoading == false`, `error == nil`).
- Redundant: from a dirty state (`isLoading == true`, `error` set), an
  identical-entitlement `customerInfoUpdated` → entitlement unchanged
  **and** bookkeeping still ran (`isLoading == false`, `error == nil`).

Tier 2 — **Store-level suppression regression guard** (not a plugin-guard
pin; per Revision 2 there is no plugin guard). Host `PaywallPlugin` in a
real `Store` via `PluginHost` (precedent: `StoreBindingTests`
`withObservationTracking` + `TrackingFlag`; hand-written `SwiduxObservable`
conformance mirroring `StoreTests.swift`). Redundant `customerInfoUpdated`
`send` → tracking does **not** re-fire; genuine entitlement change `send` →
it **does**. `await Task.yield()` before asserting. This pins the Store's
pack/unpack + plain-assignment `apply` + `@Observable` equality behavior, so
a regression there (or losing `Equatable` on `PaywallState`) is caught.
Shipped as `Tests/SwiduxPaywallTests/PaywallPluginSuppressionTests.swift`.

## Out of scope

- **No code change to any of the three plugins** (see Revision 2 — the
  guard is inert under the Swidux Store; the convention doc is the fix).
- No `*Action` enum, `*Service` protocol, or factory changes. API surface
  unchanged.
- No state-shape decomposition.
- `recordExposure` unchanged (already correct; cited as precedent).
- No shared `reconcile` helper.
- `AnalyticsPlugin` untouched (identity diff already handles identify;
  state observation is already deduplicated by the Store).

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
