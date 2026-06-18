//
//  FeatureFlagsDemo.swift
//  Counter
//

import Foundation
import SwiduxFeatureFlags
import SwiftUI

// MARK: - Bundled service

/// Test-only service that loads the wire format from a JSON file in the bundle.
struct BundledFeatureFlagsService: FeatureFlagsService {
    let bundle: Bundle
    let resourceName: String

    init(bundle: Bundle = .main, resourceName: String = "feature-flags") {
        self.bundle = bundle
        self.resourceName = resourceName
    }

    func fetch() async throws -> FeatureFlagsConfig {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw URLError(.fileDoesNotExist)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FeatureFlagsConfig.self, from: data)
    }
}

// MARK: - Typed flag keys

extension BoolFlag {
    static let showCelebrationEmoji = BoolFlag("show_celebration_emoji")
}

enum CounterButtonStyle: String { case control, treatment }

extension VariantFlag where Variant == CounterButtonStyle {
    static let counterButtonStyle = VariantFlag("counter_button_style", default: .control)
}

extension ValueFlag where Value == Int {
    static let maxCounters = ValueFlag("max_counters", default: 3)
}

// MARK: - Governance manifest

/// Every feature flag, with its required owner and expiry. The `noForeverFlags`
/// unit test fails — naming the flag and owner — when any of these expires, so a
/// stale flag can't quietly live forever. Adding a flag here is the one place
/// owner/expiry are enforced (the factory parameters are non-optional).
enum FlagManifest {
    /// Far-future demo expiries. Real apps set these to a realistic clean-up date.
    static let all: [FlagDescriptor] = [
        .bool(
            .showCelebrationEmoji, owner: "growth",
            expires: Date(timeIntervalSince1970: 1_798_761_600),  // 2027-01-01
            purpose: "Celebrate non-zero counts with 🎉"
        ),
        .variant(
            .counterButtonStyle, owner: "design",
            expires: Date(timeIntervalSince1970: 1_798_761_600),  // 2027-01-01
            purpose: "Borderless vs. bordered counter buttons (A/B)"
        ),
        .value(
            .maxCounters, owner: "platform",
            expires: Date(timeIntervalSince1970: 1_798_761_600),  // 2027-01-01
            purpose: "Remote cap on the number of counters"
        ),
    ]
}

// MARK: - Demo view

/// Demo screen showing all three flag types reading from a bundled JSON config.
struct FeatureFlagsDemoView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { store.featureFlags.isEnabled(.showCelebrationEmoji) },
                        set: { newValue in
                            store.send(
                                .featureFlags(
                                    .setLocalOverride(
                                        key: BoolFlag.showCelebrationEmoji.key,
                                        value: .bool(newValue)
                                    )))
                        }
                    )
                ) {
                    Text(BoolFlag.showCelebrationEmoji.key).monospaced()
                }
            } header: {
                Text("Boolean")
            } footer: {
                Text("Decorates non-zero counters with a 🎉 emoji beside their count.")
            }

            Section {
                Picker(
                    selection: Binding(
                        get: { store.featureFlags.variant(of: .counterButtonStyle) },
                        set: { newValue in
                            store.send(
                                .featureFlags(
                                    .setLocalOverride(
                                        key: VariantFlag<CounterButtonStyle>.counterButtonStyle.key,
                                        value: .string(newValue.rawValue)
                                    )))
                        }
                    )
                ) {
                    Text("control").tag(CounterButtonStyle.control)
                    Text("treatment").tag(CounterButtonStyle.treatment)
                } label: {
                    Text(VariantFlag<CounterButtonStyle>.counterButtonStyle.key).monospaced()
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Variant")
            } footer: {
                Text("A/B visual for the +/- buttons: outlined (control) or bordered chrome (treatment).")
            }

            Section {
                Stepper(
                    value: Binding(
                        get: { store.featureFlags.value(of: .maxCounters) },
                        set: { newValue in
                            store.send(
                                .featureFlags(
                                    .setLocalOverride(
                                        key: ValueFlag<Int>.maxCounters.key,
                                        value: .int(newValue)
                                    )))
                        }
                    ), in: 1...20
                ) {
                    LabeledContent {
                        Text("\(store.featureFlags.value(of: .maxCounters))").monospaced()
                    } label: {
                        Text(ValueFlag<Int>.maxCounters.key).monospaced()
                    }
                }
            } header: {
                Text("Value")
            } footer: {
                Text("Maximum number of counters a user can create.")
            }

            Section {
                Button("Clear local overrides") {
                    store.send(.featureFlags(.clearAllLocalOverrides))
                }
                .disabled(store.featureFlags.localOverrides.isEmpty)
            } footer: {
                Text("Local overrides beat the bundled config. Clear them to fall back to feature-flags.json.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Feature Flags")
        .toolbar {
            ToolbarItemGroup {
                if store.featureFlags.isFetching {
                    ProgressView().controlSize(.small)
                }
                Button {
                    store.send(.featureFlags(.refresh))
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help(refreshHelpText)
            }
        }
    }

    /// Tooltip text exposing the last-fetched timestamp without giving it
    /// permanent screen real estate.
    private var refreshHelpText: String {
        if let last = store.featureFlags.lastFetchedAt {
            "Last fetched at \(last.formatted(date: .omitted, time: .standard))"
        } else {
            "Refresh from bundle"
        }
    }
}
