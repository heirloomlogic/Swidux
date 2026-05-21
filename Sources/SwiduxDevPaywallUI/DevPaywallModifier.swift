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
                #if os(macOS)
            .frame(minWidth: 400, minHeight: 600)
                #endif
        }
    }
}

/// A bare-bones debug paywall: status readout, entitlement toggles,
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

    /// The debug paywall content: header, status, entitlement toggles, flows, QA toggles.
    public var body: some View {
        VStack(spacing: 0) {
            header
            List {
                Section {
                    LabeledContent("Reason", value: state.requestedReason ?? "—")
                    LabeledContent("Gate satisfied", value: state.isGateSatisfied ? "Yes" : "No")
                    LabeledContent("Loading", value: state.isLoading ? "Yes" : "No")
                    LabeledContent("Error", value: state.error ?? "—")
                }

                Section("Entitlements") {
                    Toggle("Pro", isOn: isProBinding)
                    Toggle("Permanent license", isOn: permanentLicenseBinding)
                    Button {
                        Task { await service.grantTrial() }
                    } label: {
                        Label("Start trial", systemImage: "gift")
                    }
                }

                Section("Flows") {
                    Button {
                        onAction(.restorePurchases)
                    } label: {
                        Label("Restore purchases", systemImage: "arrow.clockwise")
                    }
                    Button {
                        onAction(.refreshCustomerInfo)
                    } label: {
                        Label("Refresh customer info", systemImage: "arrow.triangle.2.circlepath")
                    }
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
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Status")
                .font(.largeTitle)
                .fontWeight(.semibold)
            Spacer()
            Button {
                onAction(.dismiss)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    // No `store.binding(_:sending:)` here: this view receives a `PaywallState`
    // snapshot (no observer tree to bind through) and toggles drive the
    // simulation surface on `SimulatedPaywallService` rather than dispatching a
    // `PaywallAction` — neither shape fits the store-binding convenience.
    private var isProBinding: Binding<Bool> {
        Binding(
            get: { state.isPro },
            set: { newValue in
                let permanent = state.hasPermanentLicense
                Task {
                    await service.setEntitlement(isPro: newValue, hasPermanentLicense: permanent)
                }
            }
        )
    }

    private var permanentLicenseBinding: Binding<Bool> {
        Binding(
            get: { state.hasPermanentLicense },
            set: { newValue in
                let isPro = state.isPro
                Task {
                    await service.setEntitlement(isPro: isPro, hasPermanentLicense: newValue)
                }
            }
        )
    }
}
