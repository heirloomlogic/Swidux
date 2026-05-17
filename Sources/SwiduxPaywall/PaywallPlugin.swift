//
//  PaywallPlugin.swift
//  SwiduxPaywall
//

import Foundation
import Swidux

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A Swidux plugin that manages paywall state and entitlement checking.
@MainActor
public struct PaywallPlugin<RootState, RootAction>: SwiduxPlugin {
    /// Root state type of the host app.
    public typealias State = RootState
    /// Root action type of the host app.
    public typealias Action = RootAction

    private let stateKeyPath: WritableKeyPath<RootState, PaywallState>
    private let toRootAction: @Sendable (PaywallAction) -> RootAction
    private let extractAction: @Sendable (RootAction) -> PaywallAction?
    private let service: any PaywallService
    private let openURL: @Sendable (URL) async -> Void

    /// Creates a paywall plugin wired into the host app.
    public init(
        state: WritableKeyPath<RootState, PaywallState>,
        action toRootAction: @escaping @Sendable (PaywallAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> PaywallAction?,
        service: any PaywallService,
        openURL: @escaping @Sendable (URL) async -> Void = { url in
            #if canImport(UIKit)
            await MainActor.run { UIApplication.shared.open(url) }
            #elseif canImport(AppKit)
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            #endif
        }
    ) {
        self.stateKeyPath = state
        self.toRootAction = toRootAction
        self.extractAction = extractAction
        self.service = service
        self.openURL = openURL
    }

    /// Routes paywall actions and returns effects for async work.
    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        let localEffect = reduceLocal(state: &state[keyPath: stateKeyPath], action: local)
        guard let localEffect else { return nil }
        let lift = toRootAction
        return { send in
            await localEffect { localAction in
                send(lift(localAction))
            }
        }
    }

    private func reduceLocal(
        state: inout PaywallState,
        action: PaywallAction
    ) -> Effect<PaywallAction>? {
        switch action {
        case .request(let reason):
            state.isPresented = true
            state.requestedReason = reason

        case .dismiss:
            state.isPresented = false
            state.requestedReason = nil
            return { send in await send(.refreshCustomerInfo) }

        case .observeCustomerInfo:
            let service = self.service
            return { send in
                for await snapshot in service.customerInfoStream() {
                    await send(.customerInfoUpdated(snapshot))
                }
            }

        case .refreshCustomerInfo:
            state.isLoading = true
            let service = self.service
            return { send in
                do {
                    let snapshot = try await service.customerInfo()
                    await send(.customerInfoUpdated(snapshot))
                } catch {
                    await send(.refreshFailed(error.localizedDescription))
                }
            }

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

        case .refreshFailed(let message):
            state.isLoading = false
            state.error = message

        case .restorePurchases:
            state.isLoading = true
            let service = self.service
            return { send in
                do {
                    let snapshot = try await service.restorePurchases()
                    await send(.customerInfoUpdated(snapshot))
                } catch {
                    await send(.refreshFailed(error.localizedDescription))
                }
            }

        case .presentCustomerCenter:
            state.isCustomerCenterPresented = true

        case .dismissCustomerCenter:
            state.isCustomerCenterPresented = false

        case .openManageSubscriptions:
            let openURL = self.openURL
            return { _ in
                if let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
                    await openURL(url)
                }
            }
        }
        return nil
    }
}
