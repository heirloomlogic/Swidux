//
//  KillswitchBlockerModifier.swift
//  SwiduxKillswitch
//
//  View modifier that enforces killswitch blocking at the UI layer.
//

import SwiftUI

extension View {
    /// Overlays a non-dismissible blocker when the killswitch verdict is `.blocked`.
    public func killswitchBlocker(
        verdict: KillswitchVerdict,
        onUpdate: (() -> Void)? = nil
    ) -> some View {
        modifier(
            KillswitchBlockerModifier(verdict: verdict) { title, message, hasUpdateURL in
                KillswitchBlockerView(
                    title: title,
                    message: message,
                    onUpdate: hasUpdateURL ? onUpdate : nil
                )
            }
        )
    }

    /// Overlays a custom non-dismissible blocker when the killswitch verdict is `.blocked`.
    public func killswitchBlocker<Blocker: View>(
        verdict: KillswitchVerdict,
        @ViewBuilder blocker: @escaping (_ title: String?, _ message: String?, _ hasUpdateURL: Bool) -> Blocker
    ) -> some View {
        modifier(KillswitchBlockerModifier(verdict: verdict, blocker: blocker))
    }
}

struct KillswitchBlockerModifier<Blocker: View>: ViewModifier {
    let verdict: KillswitchVerdict
    @ViewBuilder let blocker: (_ title: String?, _ message: String?, _ hasUpdateURL: Bool) -> Blocker

    func body(content: Content) -> some View {
        content
            .disabled(verdict.isBlocked)
            .overlay {
                if case .blocked(let title, let message, _) = verdict {
                    // Offer the Update button only for URLs the plugin will
                    // actually open — a remote config with a disallowed scheme
                    // must not render a dead button on a non-dismissible blocker.
                    blocker(title, message, verdict.openableUpdateURL != nil)
                }
            }
    }
}

struct KillswitchBlockerView: View {
    let title: String?
    let message: String?
    let onUpdate: (() -> Void)?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text(title ?? "Update Required")
                    .font(.title2.bold())

                Text(message ?? "This version is no longer supported.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if let onUpdate {
                    Button("Update", action: onUpdate)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .padding(32)
        }
    }
}
