//
//  PaywallPluginSuppressionTests.swift
//  SwiduxPaywallTests
//
//  Store-level regression guard: a redundant `customerInfoUpdated` (identical
//  entitlement) must not notify the observed `paywall` slice, while a real
//  entitlement change must. Suppression is provided by the Store's
//  pack/unpack cycle — `State.apply` assigns the slice with a plain setter,
//  and @Observable equality-gates equal values. This pins that behavior so a
//  regression in `apply`/`@Observable` equality (or losing `Equatable` on
//  `PaywallState`) is caught. It is NOT a plugin-internal guard test — the
//  reducer carries no reconcile guard (see
//  docs/plans/2026-05-16-service-result-reconcile-design.md, Revision 2).
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
        // Unconditional plain assignment — mirrors the generated `apply`
        // (ConformanceGenerator) and the other Store test mocks. The
        // suppression under test must come from @Observable's setter
        // equality-gating an equal value, NOT from a guard in this mock.
        observer.paywall = snapshot.paywall
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
    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }
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
        store.send(
            .paywall(
                .customerInfoUpdated(
                    EntitlementSnapshot(isPro: true)
                )))
        await Task.yield()

        let flag = TrackingFlag()
        withObservationTracking {
            _ = store.paywall.isPro
        } onChange: {
            flag.mark()
        }

        store.send(
            .paywall(
                .customerInfoUpdated(
                    EntitlementSnapshot(isPro: true)
                )))
        await Task.yield()

        #expect(flag.fired == false)
    }

    @Test("real entitlement change notifies the paywall slice")
    func realChangeNotifies() async {
        let store = makeStore()
        store.send(
            .paywall(
                .customerInfoUpdated(
                    EntitlementSnapshot(isPro: false)
                )))
        await Task.yield()

        let flag = TrackingFlag()
        withObservationTracking {
            _ = store.paywall.isPro
        } onChange: {
            flag.mark()
        }

        store.send(
            .paywall(
                .customerInfoUpdated(
                    EntitlementSnapshot(isPro: true)
                )))
        await Task.yield()

        #expect(flag.fired == true)
    }
}
