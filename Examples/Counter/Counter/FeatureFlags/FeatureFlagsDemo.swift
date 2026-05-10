//
//  FeatureFlagsDemo.swift
//  Counter
//
//  Self-contained demo of SwiduxFeatureFlags.
//
//  To wire into the Counter Xcode app:
//
//  1. Add the SwiduxFeatureFlags package product to the Counter target.
//  2. Add this file and `feature-flags.json` to the Counter target.
//  3. In `AppState.swift`, add: `@Slice var featureFlags: FeatureFlagsState = .init()`.
//  4. In `AppAction.swift`, add: `case featureFlags(FeatureFlagsAction)`.
//  5. In `AppReducer.swift`, route `.featureFlags` to a reducer arm that returns nil
//     (the plugin handles all state mutation).
//  6. In `AppStore.configured(...)`, register a `FeatureFlagsPlugin` with the
//     `BundledFeatureFlagsService` below.
//  7. In `ContentView.swift`, add a `NavigationLink` to `FeatureFlagsDemoView()`.

import Foundation
import SwiftUI
import SwiduxFeatureFlags

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
                    Text(enabled ? "ON \(enabled ? "🎉" : "")" : "OFF")
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
