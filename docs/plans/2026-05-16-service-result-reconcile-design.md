# Service-result reconcile: suppress redundant entitlement/verdict/config signals

Date: 2026-05-16
Status: Approved design (pre-implementation)
Scope: **code change: `SwiduxPaywall` only**; documented convention: all three

## Revision 2026-05-16 — scope narrowed to Paywall

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

### KillswitchPlugin / FeatureFlagsPlugin — no code change

Per the revision above, a reconcile guard in `verdictReceived` /
`refreshSucceeded` has no observable effect (the per-poll
`lastFetch`/`lastFetchedAt` write churns the whole slice regardless, and the
verdict/config payload is already `==` on a no-op cycle for value-diffing
consumers). They are covered by the documented convention only.

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

## Testing (Paywall only)

Two tiers in `Tests/SwiduxPaywallTests/PaywallPluginTests.swift` (no new
test target).

Tier 1 — reducer behavior (existing harness style):
- Transition: a `customerInfoUpdated` snapshot whose entitlement differs from
  current → `isPro`/`hasPermanentLicense` updated **and** bookkeeping applied
  (`isLoading == false`, `error == nil`).
- Redundant: from a non-loading state, an identical-entitlement
  `customerInfoUpdated` → entitlement unchanged **and** bookkeeping still ran
  (`isLoading == false`, `error == nil`).

Tier 2 — suppression regression guard (pins `if changed`; Tier 1 value
assertions cannot, since the value is identical either way): host
`PaywallPlugin` in a real `Store` via `PluginHost` (precedent:
`StoreBindingTests` `withObservationTracking` + `TrackingFlag`). Requires a
local `SwiduxObservable` test state with an `@Observable` observer holding
`var paywall: PaywallState` (hand-written conformance, mirroring
`StoreTests.swift`). On the stream path (entitlement steady, not loading):
redundant `customerInfoUpdated` `send` → tracking does **not** re-fire;
genuine entitlement change `send` → it **does**. `await Task.yield()` before
asserting (Observation callbacks fire next runloop tick).

## Out of scope

- **No code change to `KillswitchPlugin` / `FeatureFlagsPlugin`** (see
  Revision — a guard there is inert; convention doc covers them).
- No `PaywallAction` enum, `PaywallService` protocol, or factory changes.
  API surface unchanged.
- No state-shape decomposition (rejected option 3 — separately-observed
  fields).
- `recordExposure` unchanged (already correct; cited as precedent).
- No shared `reconcile` helper.
- `AnalyticsPlugin` untouched (identity diff already handles identify; this
  makes the Paywall state it derives from truthful).

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
