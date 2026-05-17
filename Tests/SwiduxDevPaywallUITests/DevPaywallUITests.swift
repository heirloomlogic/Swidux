//
//  DevPaywallUITests.swift
//  SwiduxDevPaywallUITests
//

import SwiduxPaywall
import SwiftUI
import Testing

@testable import SwiduxDevPaywallUI

@Suite("SwiduxDevPaywallUI")
@MainActor
struct DevPaywallUITests {
    @Test("DevPaywallView is constructible with paywall state and a simulator")
    func devPaywallViewConstructs() {
        let service = SimulatedPaywallService()
        _ = DevPaywallView(
            state: PaywallState(),
            service: service,
            onAction: { _ in }
        )
    }

    @Test("the .devPaywall modifier is applicable to a view")
    func devPaywallModifierApplies() {
        let service = SimulatedPaywallService()
        // Smoke: the modifier compiles and constructs against a real view.
        // The opaque return type has nothing meaningful to assert.
        _ = Color.clear.devPaywall(
            state: PaywallState(isPro: true),
            service: service,
            onAction: { _ in }
        )
    }
}
