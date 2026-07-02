//
//  PaywallTestHarness.swift
//  SwiduxPaywallTests
//
//  Shared root-state/action/plugin scaffolding for the paywall test suites.
//

import Foundation
import Swidux

@testable import SwiduxPaywall

struct TestState: Sendable, Equatable {
    var paywall = PaywallState()
}

enum TestAction: Sendable {
    case paywall(PaywallAction)
    case unrelated
}

@MainActor
func makePlugin(
    service: any PaywallService = MockPaywallService(),
    openURL: @escaping @Sendable (URL) async -> Void = { _ in }
) -> PaywallPlugin<TestState, TestAction> {
    PaywallPlugin(
        state: \.paywall,
        action: TestAction.paywall,
        extractAction: {
            if case .paywall(let a) = $0 { return a }
            return nil
        },
        service: service,
        openURL: openURL
    )
}

@MainActor
func collectActions(
    from effect: Effect<TestAction>?
) async throws -> [PaywallAction] {
    guard let effect else { return [] }
    var collected: [PaywallAction] = []
    try await effect { action in
        if case .paywall(let a) = action {
            collected.append(a)
        }
    }
    return collected
}
