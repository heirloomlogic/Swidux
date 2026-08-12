//
//  SimulatedPaywallService.swift
//  SwiduxPaywall
//

import Foundation
import os

/// Errors thrown by ``SimulatedPaywallService`` when a failure is simulated.
public enum SimulatedPaywallError: Error, Equatable {
    /// `restorePurchases()` failed because restore-failure simulation is on.
    case restoreFailed
    /// `customerInfo()` failed because refresh-failure simulation is on.
    case refreshFailed
}

/// A stateful, fully driveable ``PaywallService`` for development and QA.
///
/// Use this as the `service:` while the paywall vendor decision is still open.
/// It behaves like a micro version of the real thing: entitlement changes are
/// pushed through ``customerInfoStream()`` so they flow through the real
/// `PaywallPlugin` pipeline and survive later refresh/restore — exactly as a
/// RevenueCat/StoreKit service would.
///
/// The simulation surface (`grantPro()`, `setRestoreShouldFail(_:)`, …) is not
/// part of ``PaywallService``; the dev paywall UI in `SwiduxDevPaywallUI`
/// drives it. Hold a single instance and pass it to both `Store.configured()`
/// and the `.devPaywall(...)` view.
///
/// `EntitlementSnapshot` only models `isPro` / `hasPermanentLicense`, so a
/// "trial" yields `isPro == true` and is distinguished only in the log line.
///
/// > Warning: This service simulates purchases — nothing is charged and no
/// > receipt exists. Release builds are supported so TestFlight/QA can drive
/// > the paywall vendor-free, but the service logs a fault at init in Release
/// > as a submission tripwire: replace it with a real `PaywallService` before
/// > shipping to the App Store.
public actor SimulatedPaywallService: PaywallService {
    private var current: EntitlementSnapshot
    private var continuations: [UUID: AsyncStream<EntitlementSnapshot>.Continuation] = [:]
    private var restoreShouldFail = false
    private var refreshShouldFail = false
    private var artificialDelay: Duration = .zero
    private let logger: Logger

    /// Creates a simulated paywall service with an initial entitlement.
    public init(
        isPro: Bool = false,
        hasPermanentLicense: Bool = false,
        subsystem: String = "Swidux",
        category: String = "Paywall"
    ) {
        self.current = EntitlementSnapshot(isPro: isPro, hasPermanentLicense: hasPermanentLicense)
        self.logger = Logger(subsystem: subsystem, category: category)
        #if !DEBUG
        // Deliberate for TestFlight/QA, fatal for the App Store. Loud and
        // greppable in Console/sysdiagnose during submission prep.
        logger.fault(
            """
            SimulatedPaywallService active in a Release build — purchases are \
            SIMULATED. Replace with a real PaywallService before App Store submission.
            """
        )
        #endif
    }

    // MARK: - PaywallService

    /// Returns the current entitlement, after any simulated latency, throwing
    /// ``SimulatedPaywallError/refreshFailed`` when refresh-failure is on.
    public func customerInfo() async throws -> EntitlementSnapshot {
        try await applyDelay()
        if refreshShouldFail {
            logger.info("customerInfo -> simulated failure")
            throw SimulatedPaywallError.refreshFailed
        }
        logger.info("customerInfo -> \(self.describe(self.current), privacy: .public)")
        return current
    }

    /// A long-lived multicast stream that yields the current entitlement
    /// immediately and again on every simulated change.
    public nonisolated func customerInfoStream() -> AsyncStream<EntitlementSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
            // Registration hops onto the actor, so it lands after this call
            // returns. Anything granted in that window would reach a
            // continuation the actor hasn't seen — the stream's *first* value
            // is the current snapshot, replayed on registration, so a late
            // registration still delivers the latest state rather than an
            // update that was missed. `register` yields it for exactly that.
            Task { await self.register(id, continuation) }
        }
    }

    /// Returns the current entitlement, after any simulated latency, throwing
    /// ``SimulatedPaywallError/restoreFailed`` when restore-failure is on.
    public func restorePurchases() async throws -> EntitlementSnapshot {
        try await applyDelay()
        if restoreShouldFail {
            logger.info("restorePurchases -> simulated failure")
            throw SimulatedPaywallError.restoreFailed
        }
        logger.info("restorePurchases -> \(self.describe(self.current), privacy: .public)")
        return current
    }

    // MARK: - Simulation controls (driven by the dev paywall UI)

    /// Grants an active pro subscription and broadcasts it.
    public func grantPro() {
        update(EntitlementSnapshot(isPro: true), label: "grant pro")
    }

    /// Grants a trial. Modeled as `isPro == true`; logged as a trial.
    public func grantTrial() {
        update(EntitlementSnapshot(isPro: true), label: "grant trial")
    }

    /// Grants a permanent/lifetime license and broadcasts it.
    public func grantPermanentLicense() {
        update(EntitlementSnapshot(hasPermanentLicense: true), label: "grant permanent license")
    }

    /// Revokes all entitlement and broadcasts the free snapshot.
    public func setFree() {
        update(EntitlementSnapshot(), label: "set free")
    }

    /// Sets the entitlement from independent flags and broadcasts it.
    ///
    /// Unlike ``grantPro()`` / ``grantPermanentLicense()`` (which are mutually
    /// exclusive), this lets the dev paywall toggle each bit without clobbering
    /// the other.
    public func setEntitlement(isPro: Bool, hasPermanentLicense: Bool) {
        update(
            EntitlementSnapshot(isPro: isPro, hasPermanentLicense: hasPermanentLicense),
            label: "set entitlement"
        )
    }

    /// Toggles whether `restorePurchases()` throws.
    public func setRestoreShouldFail(_ shouldFail: Bool) {
        restoreShouldFail = shouldFail
        logger.info("restoreShouldFail = \(shouldFail, privacy: .public)")
    }

    /// Toggles whether `customerInfo()` throws.
    public func setRefreshShouldFail(_ shouldFail: Bool) {
        refreshShouldFail = shouldFail
        logger.info("refreshShouldFail = \(shouldFail, privacy: .public)")
    }

    /// Sets an artificial latency applied to `customerInfo()` / `restorePurchases()`.
    public func setArtificialDelay(_ delay: Duration) {
        artificialDelay = delay
        logger.info("artificialDelay = \(delay, privacy: .public)")
    }

    // MARK: - Internals

    private func update(_ snapshot: EntitlementSnapshot, label: String) {
        guard snapshot != current else {
            logger.info("\(label, privacy: .public) -> unchanged")
            return
        }
        current = snapshot
        logger.info("\(label, privacy: .public) -> \(self.describe(snapshot), privacy: .public)")
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func register(
        _ id: UUID,
        _ continuation: AsyncStream<EntitlementSnapshot>.Continuation
    ) {
        continuations[id] = continuation
        continuation.yield(current)
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func applyDelay() async throws {
        guard artificialDelay > .zero else { return }
        try await Task.sleep(for: artificialDelay)
    }

    private func describe(_ snapshot: EntitlementSnapshot) -> String {
        "isPro=\(snapshot.isPro) hasPermanentLicense=\(snapshot.hasPermanentLicense)"
    }
}
