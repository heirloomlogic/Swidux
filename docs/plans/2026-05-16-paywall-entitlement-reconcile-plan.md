# Paywall Entitlement Reconcile Implementation Plan

> **SUPERSEDED (2026-05-16, Revision 2 of the design doc).** Execution
> verification proved the reducer guard inert in the Swidux Store
> (`Store.send` mutates a local struct copy; `State.apply` plain assignment
> is `@Observable` equality-gated — dedup is a Store property, not a plugin
> guard). The guard (Task 1) was reverted in commit 6252fb7. Task 2's test
> is retained but reframed as a Store-level suppression regression test.
> The real fix is Task 3 (convention docs) only. Tasks 1–2 below are
> retained for the decision trail; do not re-implement the guard.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `PaywallPlugin.customerInfoUpdated` reconcile the entitlement only when it actually changed, so a steady-state stream tick no longer propagates a spurious entitlement transition, while keeping per-cycle bookkeeping unconditional.

**Architecture:** Reducer-level guard (design Approach A). The `customerInfoUpdated` case always clears `isLoading`/`error` (bookkeeping), then assigns `isPro`/`hasPermanentLicense` only when the incoming snapshot differs from current state. Killswitch/FeatureFlags get a documented convention only (no code change — see design Revision). Source of truth: `docs/plans/2026-05-16-service-result-reconcile-design.md`.

**Tech Stack:** Swift, Swift Testing (`@Test`/`#expect`), Swidux `Store`/`PluginHost`/`SwiduxObservable`, Persnicket (`swift-format`) for lint.

---

### Task 1: Tier 1 — redundant-cycle reducer test (TDD)

**Files:**
- Test: `Tests/SwiduxPaywallTests/PaywallPluginTests.swift` (add after the existing `customerInfoUpdatedSetsEntitlements` test, ~line 100)
- Modify: `Sources/SwiduxPaywall/PaywallPlugin.swift:97-101`

**Step 1: Write the failing test**

Add to `PaywallPluginTests` (the `@Suite`/`@MainActor` struct):

```swift
@Test("customerInfoUpdated keeps unchanged entitlement but still clears loading/error")
func customerInfoUpdatedRedundantCycleStillBookkeeps() {
    let plugin = makePlugin()
    var state = TestState()
    state.paywall.isPro = true
    state.paywall.isLoading = true
    state.paywall.error = "stale"

    let snapshot = EntitlementSnapshot(isPro: true, hasPermanentLicense: false)
    _ = plugin.reduce(
        state: &state,
        action: .paywall(.customerInfoUpdated(snapshot))
    )

    // Meaningful payload unchanged.
    #expect(state.paywall.isPro == true)
    #expect(state.paywall.hasPermanentLicense == false)
    // Bookkeeping ran unconditionally.
    #expect(state.paywall.isLoading == false)
    #expect(state.paywall.error == nil)
}
```

**Step 2: Run the test, expect PASS-by-accident or value PASS**

Run: `swift test --filter PaywallPlugin/customerInfoUpdatedRedundantCycleStillBookkeeps`

Expected: PASS even before the guard (current code already produces these values). This Tier 1 test pins bookkeeping + value correctness; it does **not** prove the guard (Tier 2 does). Keep it — it documents the contract and guards against a bookkeeping regression.

**Step 3: Apply the reducer guard**

In `Sources/SwiduxPaywall/PaywallPlugin.swift`, replace the `case .customerInfoUpdated` body (currently lines 97-101):

```swift
        case .customerInfoUpdated(let snapshot):
            state.isPro = snapshot.isPro
            state.hasPermanentLicense = snapshot.hasPermanentLicense
            state.isLoading = false
            state.error = nil
```

with:

```swift
        case .customerInfoUpdated(let snapshot):
            // Bookkeeping: every stream tick / refresh / restore resolves
            // loading and clears errors.
            state.isLoading = false
            state.error = nil
            // Reconcile entitlement only on real change so observers see one
            // transition, not stream noise. The `inout` path bypasses
            // @Observable equality, so the guard is load-bearing.
            let changed =
                snapshot.isPro != state.isPro
                || snapshot.hasPermanentLicense != state.hasPermanentLicense
            if changed {
                state.isPro = snapshot.isPro
                state.hasPermanentLicense = snapshot.hasPermanentLicense
            }
```

**Step 4: Run Tier 1 + the existing transition test**

Run: `swift test --filter PaywallPlugin`

Expected: PASS, including the pre-existing `customerInfoUpdated sets isPro and hasPermanentLicense` (transition still works) and the new redundant test.

**Step 5: Commit**

```bash
git add Sources/SwiduxPaywall/PaywallPlugin.swift Tests/SwiduxPaywallTests/PaywallPluginTests.swift
git commit -m "Reconcile paywall entitlement only on change

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Tier 2 — suppression regression test (the test that pins the guard)

This is the only test that fails if the `if changed` guard is deleted. It hosts the plugin in a real `Store` and asserts the observed `paywall` slice does not notify on a redundant stream cycle but does on a real change.

**Files:**
- Test: `Tests/SwiduxPaywallTests/PaywallPluginSuppressionTests.swift` (new file)

**Step 1: Write the failing test**

Create `Tests/SwiduxPaywallTests/PaywallPluginSuppressionTests.swift`:

```swift
//
//  PaywallPluginSuppressionTests.swift
//  SwiduxPaywallTests
//
//  Tier 2: pins the reconcile guard via real Store observation.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxPaywall

// MARK: - Observable test state (hand-written, mirrors StoreTests.swift)

@Observable
@MainActor
final class ObservedPaywallObserver {
    var paywall: PaywallState
    init(paywall: PaywallState = PaywallState()) { self.paywall = paywall }
}

struct ObservedPaywallState: Sendable, Equatable {
    var paywall = PaywallState()
}

extension ObservedPaywallState: SwiduxObservable {
    typealias Observer = ObservedPaywallObserver

    @MainActor init(observer: ObservedPaywallObserver) {
        self.paywall = observer.paywall
    }
    @MainActor static func makeObserver(
        from state: ObservedPaywallState
    ) -> ObservedPaywallObserver {
        ObservedPaywallObserver(paywall: state.paywall)
    }
    @MainActor static func apply(
        _ snapshot: ObservedPaywallState, to observer: ObservedPaywallObserver
    ) {
        if observer.paywall != snapshot.paywall { observer.paywall = snapshot.paywall }
    }
    @MainActor static func applyRestore(
        from snapshot: ObservedPaywallState, to current: inout ObservedPaywallState
    ) {
        current.paywall = snapshot.paywall
    }
}

enum ObservedPaywallAction: Sendable {
    case paywall(PaywallAction)
}

private final class TrackingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func mark() { lock.lock(); value = true; lock.unlock() }
}

@Suite("PaywallPlugin suppression")
@MainActor
struct PaywallPluginSuppressionTests {

    private func makeStore() -> Store<ObservedPaywallState, ObservedPaywallAction> {
        let plugin = PaywallPlugin<ObservedPaywallState, ObservedPaywallAction>(
            state: \.paywall,
            action: ObservedPaywallAction.paywall,
            extractAction: {
                if case .paywall(let a) = $0 { return a }
                return nil
            },
            service: MockPaywallService(),
            openURL: { _ in }
        )
        let host = PluginHost<ObservedPaywallState, ObservedPaywallAction>()
        host.register(plugin)
        return Store(
            initialState: ObservedPaywallState(),
            reducer: { _, _ in nil },
            plugins: host
        )
    }

    @Test("redundant snapshot does not notify the paywall slice")
    func redundantSnapshotIsSilent() async {
        let store = makeStore()
        // Establish steady state: pro, not loading.
        store.send(.paywall(.customerInfoUpdated(
            EntitlementSnapshot(isPro: true)
        )))
        await Task.yield()

        let flag = TrackingFlag()
        withObservationTracking {
            _ = store.paywall.isPro
        } onChange: {
            flag.mark()
        }

        // Identical entitlement → guard suppresses the write → no notification.
        store.send(.paywall(.customerInfoUpdated(
            EntitlementSnapshot(isPro: true)
        )))
        await Task.yield()

        #expect(flag.fired == false)
    }

    @Test("real entitlement change notifies the paywall slice")
    func realChangeNotifies() async {
        let store = makeStore()
        store.send(.paywall(.customerInfoUpdated(
            EntitlementSnapshot(isPro: false)
        )))
        await Task.yield()

        let flag = TrackingFlag()
        withObservationTracking {
            _ = store.paywall.isPro
        } onChange: {
            flag.mark()
        }

        store.send(.paywall(.customerInfoUpdated(
            EntitlementSnapshot(isPro: true)
        )))
        await Task.yield()

        #expect(flag.fired == true)
    }
}
```

**Step 2: Run, expect PASS**

Run: `swift test --filter "PaywallPlugin suppression"`

Expected: both PASS (guard from Task 1 is in place).

**Step 3: Verify the test actually pins the guard**

Temporarily revert the `case .customerInfoUpdated` body to the old unconditional form, then:

Run: `swift test --filter "PaywallPlugin suppression"`

Expected: `redundantSnapshotIsSilent` FAILS (slice notifies because the `inout` write bypasses `@Observable` equality). Restore the guard, re-run, expect PASS. This step proves the test has teeth; do not commit the reverted state.

**Step 4: Commit**

```bash
git add Tests/SwiduxPaywallTests/PaywallPluginSuppressionTests.swift
git commit -m "Add Tier 2 suppression test pinning the paywall reconcile guard

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Documented convention

**Files:**
- Modify: `Sources/Swidux/Documentation.docc/PluginArchitecture.md`
- Modify: `Sources/Swidux/Documentation.docc/PluginPaywallReference.md`
- Modify: `Sources/Swidux/Documentation.docc/PluginKillswitchReference.md`
- Modify: the FeatureFlags reference doc (locate via `ls Sources/Swidux/Documentation.docc/ | grep -i featureflag`)

**Step 1: Add the convention subsection to `PluginArchitecture.md`**

Add a new `## Service-result actions and transition observation` section with this text:

> A service-result action (`customerInfoUpdated`, `verdictReceived`,
> `refreshSucceeded`) fires on **every** fetch/stream tick, not only when
> the value changed. It always performs per-cycle bookkeeping (resolve
> loading, advance cache gates, clear errors). Derive analytics and side
> effects from the **state slice transition or a diffed value derived from
> it**, never from the raw service-result action — mapping a discrete event
> to the action fires duplicates by design. `PaywallPlugin` additionally
> reconciles its entitlement only on change so the observed slice stays
> silent on a steady-state stream tick. `KillswitchPlugin` /
> `FeatureFlagsPlugin` advance a bookkeeping timestamp every poll, so their
> slice notifies regardless; consume their verdict/config via a diffed value
> (e.g. `AnalyticsIdentity.userProperties`, which `AnalyticsPlugin`
> re-evaluates and diffs every dispatch) — the payload is already stable
> across a no-op cycle, so a value diff yields exactly the real transitions.

**Step 2: Update the three reference docs**

- `PluginPaywallReference.md`: update the `customerInfoUpdated` action-semantics bullet (currently "Sets `isPro` and `hasPermanentLicense` from the snapshot, clears `isLoading`, and clears `error`.") to: "Always clears `isLoading` and `error`; assigns `isPro`/`hasPermanentLicense` only when the snapshot's entitlement differs from current state, so a steady-state stream tick does not propagate a spurious transition. Cross-reference the new architecture section."
- `PluginKillswitchReference.md` and the FeatureFlags reference: add a one-sentence cross-reference to the architecture section noting verdict/config should be consumed via a diffed value, not the raw `verdictReceived`/`refreshSucceeded` action.

**Step 3: Build docs sanity (compile check is enough)**

Run: `swift build`

Expected: builds clean (docc comments don't break the build; this just confirms no stray code edits).

**Step 4: Commit**

```bash
git add Sources/Swidux/Documentation.docc/
git commit -m "Document service-result transition-observation convention

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Final verification

**Step 1: Full test suite**

Run: `swift test`

Expected: all suites PASS (no regressions in Paywall, Killswitch, FeatureFlags, Store, Analytics).

**Step 2: Lint / format (Persnicket)**

Run: `swift package plugin --allow-writing-to-package-directory format-source-code` (Persnicket `Persnipe`; if the command name differs, consult the `persnicket-ref` skill).

Expected: no diff, or apply the formatter's diff and amend the relevant commit.

**Step 3: Confirm scope**

Run: `git diff --stat origin/main...HEAD`

Expected files only: `Sources/SwiduxPaywall/PaywallPlugin.swift`, `Tests/SwiduxPaywallTests/PaywallPluginTests.swift`, `Tests/SwiduxPaywallTests/PaywallPluginSuppressionTests.swift`, `Sources/Swidux/Documentation.docc/*`, and the two design docs. **No** changes to `KillswitchPlugin.swift` or `FeatureFlagsPlugin.swift` (per design Revision).

**Step 4: Use superpowers:verification-before-completion before claiming done.**
