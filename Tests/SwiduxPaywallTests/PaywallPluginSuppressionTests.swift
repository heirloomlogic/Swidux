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
