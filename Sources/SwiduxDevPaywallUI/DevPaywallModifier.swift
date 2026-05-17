//
//  DevPaywallModifier.swift
//  SwiduxDevPaywallUI
//

import SwiduxPaywall
import SwiftUI

extension View {
    /// Presents a basic developer/QA paywall sheet driven by `state.isPresented`.
    ///
    /// Mirrors the shape of the vendor paywall UI (e.g.
    /// `.revenueCatPaywall(state:onAction:)`) so the call site is unchanged
    /// when a real provider is adopted. The sheet's buttons drive `service`
    /// directly, so simulated entitlement changes flow back through the real
    /// `PaywallPlugin` pipeline.
    ///
    /// Pass the *same* ``SimulatedPaywallService`` instance you handed to
    /// `Store.configured()`.
    ///
    /// - Parameters:
    ///   - state: The current `PaywallState` (read from the store).
    ///   - service: The shared simulated paywall service to drive.
    ///   - onAction: Dispatches a `PaywallAction` back into the store.
    /// - Returns: A view that presents the debug paywall sheet.
    public func devPaywall(
        state: PaywallState,
        service: SimulatedPaywallService,
        onAction: @escaping (PaywallAction) -> Void
    ) -> some View {
        let isPresented = Binding(
            get: { state.isPresented },
            set: { if !$0 { onAction(.dismiss) } }
        )
        return sheet(isPresented: isPresented) {
            DevPaywallView(state: state, service: service, onAction: onAction)
        }
    }
}

/// A bare-bones debug paywall: status readout, entitlement-grant buttons,
/// real restore/refresh flows, and QA failure/latency toggles.
public struct DevPaywallView: View {
    private let state: PaywallState
    private let service: SimulatedPaywallService
    private let onAction: (PaywallAction) -> Void

    @State private var restoreShouldFail = false
    @State private var refreshShouldFail = false
    @State private var delaySeconds = 0.0

    /// Creates the debug paywall view.
    public init(
        state: PaywallState,
        service: SimulatedPaywallService,
        onAction: @escaping (PaywallAction) -> Void
    ) {
        self.state = state
        self.service = service
        self.onAction = onAction
    }

    /// The debug paywall content: status, grant buttons, flows, QA toggles.
    public var body: some View {
        List {
            Section("Status") {
                LabeledContent("Reason", value: state.requestedReason ?? "—")
                LabeledContent("isPro", value: String(state.isPro))
                LabeledContent("Permanent license", value: String(state.hasPermanentLicense))
                LabeledContent("Gate satisfied", value: String(state.isGateSatisfied))
                LabeledContent("Loading", value: String(state.isLoading))
                LabeledContent("Error", value: state.error ?? "—")
            }

            Section("Grant entitlement") {
                Button("Grant Pro") { Task { await service.grantPro() } }
                Button("Grant Trial") { Task { await service.grantTrial() } }
                Button("Grant Permanent License") {
                    Task { await service.grantPermanentLicense() }
                }
                Button("Set Free", role: .destructive) {
                    Task { await service.setFree() }
                }
            }

            Section("Flows") {
                Button("Restore Purchases") { onAction(.restorePurchases) }
                Button("Refresh Customer Info") { onAction(.refreshCustomerInfo) }
            }

            Section("QA simulation") {
                Toggle("Restore fails", isOn: $restoreShouldFail)
                    .onChange(of: restoreShouldFail) { _, value in
                        Task { await service.setRestoreShouldFail(value) }
                    }
                Toggle("Refresh fails", isOn: $refreshShouldFail)
                    .onChange(of: refreshShouldFail) { _, value in
                        Task { await service.setRefreshShouldFail(value) }
                    }
                Stepper(
                    "Artificial delay: \(delaySeconds, specifier: "%.1f")s",
                    value: $delaySeconds,
                    in: 0...5,
                    step: 0.5
                )
                .onChange(of: delaySeconds) { _, value in
                    Task { await service.setArtificialDelay(.seconds(value)) }
                }
            }

            Section {
                Button("Dismiss") { onAction(.dismiss) }
            }
        }
    }
}
