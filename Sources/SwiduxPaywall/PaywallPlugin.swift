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
    private let requests = PaywallRequestGeneration()

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
        return localEffect.map(toRootAction)
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
            return Effect { send in await send(.refreshCustomerInfo) }

        case .observeCustomerInfo:
            // A second dispatch must not create another live subscription.
            guard !state.isObservingCustomerInfo else { return nil }
            state.isObservingCustomerInfo = true
            let service = self.service
            return Effect { send in
                for await snapshot in service.customerInfoStream() {
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        send(.customerInfoUpdated(snapshot))
                    }
                    if Task.isCancelled { break }
                }
                // A finished stream is not an entitlement update, so nothing
                // else would clear the guard — and the guard is what refuses
                // the next `.observeCustomerInfo`. Left latched, a service that
                // ends its stream (on teardown, or a base that finishes
                // immediately) leaves the app with no live entitlement updates
                // and no way to ask for them again.
                await send(.customerInfoStreamEnded)
            }

        case .customerInfoStreamEnded:
            state.isObservingCustomerInfo = false

        case .refreshCustomerInfo:
            state.isLoading = true
            let service = self.service
            return requestEffect { try await service.customerInfo() }

        case .customerInfoUpdated(let snapshot):
            if snapshot.source == .cacheSeed {
                // Bootstrap only. A seed may arrive while a live request is
                // suspended, or remain buffered until after it resolves.
                guard !requests.hasResolved else { return nil }
                state.isPro = snapshot.isPro
                state.hasPermanentLicense = snapshot.hasPermanentLicense
                return nil
            }
            // Stream updates and accepted request results supersede every
            // read that began before them. Check-and-send runs on MainActor,
            // so a newer update cannot interleave with a stale completion.
            requests.acceptResult()
            state.isPro = snapshot.isPro
            state.hasPermanentLicense = snapshot.hasPermanentLicense
            state.isLoading = false
            state.error = nil

        case .refreshFailed(let message):
            state.isLoading = false
            state.error = message

        case .refreshCancelled(let requestID):
            guard requests.current == requestID else { return nil }
            _ = requests.begin()
            state.isLoading = false

        case .restorePurchases:
            state.isLoading = true
            let service = self.service
            return requestEffect { try await service.restorePurchases() }

        case .presentCustomerCenter:
            state.isCustomerCenterPresented = true

        case .dismissCustomerCenter:
            state.isCustomerCenterPresented = false

        case .openManageSubscriptions:
            let openURL = self.openURL
            return Effect { _ in
                await openURL(URL(static: "itms-apps://apps.apple.com/account/subscriptions"))
            }
        }
        return nil
    }

    private func requestEffect(
        _ operation: @escaping @Sendable () async throws -> EntitlementSnapshot
    ) -> Effect<PaywallAction> {
        let requests = self.requests
        let generation = requests.begin()
        return Effect { send in
            await withTaskCancellationHandler {
                guard
                    await MainActor.run(body: {
                        guard requests.current == generation else { return false }
                        guard !Task.isCancelled else {
                            send(.refreshCancelled(requestID: generation))
                            return false
                        }
                        return true
                    })
                else { return }
                do {
                    let snapshot = try await operation()
                    await MainActor.run {
                        guard requests.current == generation else { return }
                        if Task.isCancelled {
                            send(.refreshCancelled(requestID: generation))
                        } else {
                            send(.customerInfoUpdated(snapshot))
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        guard requests.current == generation else { return }
                        if Task.isCancelled {
                            send(.refreshCancelled(requestID: generation))
                        } else {
                            send(.refreshFailed(message))
                        }
                    }
                }
            } onCancel: {
                // Providers may ignore cancellation indefinitely. Clear only
                // this request's loading on MainActor without waiting for them.
                Task { @MainActor in
                    guard requests.current == generation else { return }
                    send(.refreshCancelled(requestID: generation))
                }
            }
        }
    }
}

@MainActor
private final class PaywallRequestGeneration {
    private(set) var current = UUID()
    private(set) var hasResolved = false

    func acceptResult() {
        _ = begin()
        hasResolved = true
    }

    func begin() -> UUID {
        current = UUID()
        return current
    }
}
