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
            let requests = self.requests
            return Effect { send in
                for await snapshot in service.customerInfoStream() {
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        if snapshot.source == .live { requests.acceptStreamUpdate() }
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
            return requestEffect(requests.beginRead()) { try await service.customerInfo() }

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
            state.isLoading = requests.isLoading
            state.error = nil

        case .refreshFailed(let message):
            state.isLoading = requests.isLoading
            state.error = message

        case .refreshCancelled(let requestID):
            guard requests.end(requestID) else { return nil }
            state.isLoading = requests.isLoading

        case .restorePurchases:
            state.isLoading = true
            let service = self.service
            return requestEffect(requests.beginRestore()) { try await service.restorePurchases() }

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
        _ generation: UUID,
        _ operation: @escaping @Sendable () async throws -> EntitlementSnapshot
    ) -> Effect<PaywallAction> {
        let requests = self.requests
        return Effect { send in
            await withTaskCancellationHandler {
                guard
                    await MainActor.run(body: {
                        guard requests.isLive(generation) else { return false }
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
                        guard requests.isLive(generation) else { return }
                        if Task.isCancelled || requests.isOutranked(generation) {
                            // An outranked restore ends like a cancelled one:
                            // the stream's newer snapshot already stands.
                            send(.refreshCancelled(requestID: generation))
                        } else {
                            requests.end(generation)
                            send(.customerInfoUpdated(snapshot))
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        guard requests.isLive(generation) else { return }
                        if Task.isCancelled {
                            send(.refreshCancelled(requestID: generation))
                        } else {
                            requests.end(generation)
                            send(.refreshFailed(message))
                        }
                    }
                }
            } onCancel: {
                // Providers may ignore cancellation indefinitely. Clear only
                // this request's loading on MainActor without waiting for them.
                Task { @MainActor in
                    guard requests.isLive(generation) else { return }
                    send(.refreshCancelled(requestID: generation))
                }
            }
        }
    }
}

/// Decides which request results may still land.
///
/// Reads are ordered by when they *start*: only the newest may land, and any
/// accepted result supersedes it. A restore is a write, so it is ordered by
/// when it *completes*: its result reflects the account after the restore,
/// which is newer than anything a read resolved while it ran — even a read
/// that started later. No read therefore supersedes a restore.
///
/// The one thing that outranks a restore's snapshot is a live stream update
/// delivered after the restore began. The provider's feed is at least as new
/// as the restore, and a feed that reflects restores (RevenueCat's does)
/// re-emits the restored state anyway. A restore's error still lands.
///
/// Whether a restore may land and whether it holds the spinner are separate.
/// A provider can leave a restore suspended forever (a sign-in sheet that
/// never resolves), and nothing distinguishes that from a slow one. So an
/// accepted result releases the spinner of every restore in flight, while
/// each restore's own result or error still lands when it completes.
@MainActor
private final class PaywallRequestGeneration {
    /// The newest read, until it resolves or is superseded.
    private var currentRead: UUID?
    private var restores: [UUID: Restore] = [:]
    private(set) var hasResolved = false

    private struct Restore {
        /// Cleared once any newer result lands, so a hung restore can't pin `isLoading`.
        var holdsSpinner = true
        /// Set by a live stream update delivered after the restore began.
        var isOutranked = false
    }

    /// Whether the spinner should show: a read is in flight, or a restore no
    /// newer result has landed behind.
    var isLoading: Bool { currentRead != nil || restores.values.contains { $0.holdsSpinner } }

    func beginRead() -> UUID {
        let id = UUID()
        currentRead = id
        return id
    }

    func beginRestore() -> UUID {
        let id = UUID()
        restores[id] = Restore()
        return id
    }

    func isLive(_ id: UUID) -> Bool {
        id == currentRead || restores[id] != nil
    }

    /// Whether `id` is a restore whose snapshot a stream update has outranked.
    func isOutranked(_ id: UUID) -> Bool {
        restores[id]?.isOutranked == true
    }

    /// Ends `id`. Returns `false` if it had already ended or been superseded,
    /// so a duplicate or delayed completion changes nothing.
    @discardableResult
    func end(_ id: UUID) -> Bool {
        if restores.removeValue(forKey: id) != nil { return true }
        guard id == currentRead else { return false }
        currentRead = nil
        return true
    }

    func acceptResult() {
        currentRead = nil
        hasResolved = true
        for id in restores.keys { restores[id]?.holdsSpinner = false }
    }

    /// Marks every restore in flight as outranked by a live stream update.
    func acceptStreamUpdate() {
        for id in restores.keys { restores[id]?.isOutranked = true }
    }
}
