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

// MARK: - Demo view

/// Demo screen showing all three flag types reading from a bundled JSON config.
struct FeatureFlagsDemoView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section("Boolean flag") {
                let enabled = store.featureFlags.isEnabled(.showCelebrationEmoji)
                LabeledContent("show_celebration_emoji") {
                    Text(enabled ? "ON 🎉" : "OFF")
                }
            }

            Section("Variant flag") {
                let style = store.featureFlags.variant(of: .counterButtonStyle)
                LabeledContent("counter_button_style") {
                    Text(style.rawValue)
                }
            }

            Section("Value flag") {
                let cap = store.featureFlags.value(of: .maxCounters)
                LabeledContent("max_counters") {
                    Text("\(cap)")
                }
            }

            Section("Refresh") {
                Button("Refresh from bundle") {
                    store.send(.featureFlags(.refresh))
                }
                if let lastFetched = store.featureFlags.lastFetchedAt {
                    LabeledContent("Last fetched", value: lastFetched.formatted(date: .omitted, time: .standard))
                }
                if store.featureFlags.isFetching {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .navigationTitle("Feature Flags")
    }
}
