// swift-tools-version: 6.2

import CompilerPluginSupport
import Foundation
import PackageDescription

let package = Package(
    name: "Swidux",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "Swidux", targets: ["Swidux"]),
        .library(name: "SwiduxAnalytics", targets: ["SwiduxAnalytics"]),
        .library(name: "SwiduxFeatureFlags", targets: ["SwiduxFeatureFlags"]),
        .library(name: "SwiduxKillswitch", targets: ["SwiduxKillswitch"]),
        .library(name: "SwiduxParentalGate", targets: ["SwiduxParentalGate"]),
        .library(name: "SwiduxPaywall", targets: ["SwiduxPaywall"]),
        .library(name: "SwiduxDevPaywallUI", targets: ["SwiduxDevPaywallUI"]),
        .library(name: "SwiduxPersistence", targets: ["SwiduxPersistence"]),
        .library(name: "SwiduxCloudKitSync", targets: ["SwiduxCloudKitSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"700.0.0")
    ],
    targets: [
        .macro(
            name: "SwiduxMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .target(name: "Swidux", dependencies: ["SwiduxMacros"]),
        .target(name: "SwiduxAnalytics", dependencies: ["Swidux"]),
        .target(name: "SwiduxFeatureFlags", dependencies: ["Swidux"]),
        .target(name: "SwiduxKillswitch", dependencies: ["Swidux"]),
        .target(name: "SwiduxParentalGate", dependencies: ["Swidux"]),
        .target(name: "SwiduxPaywall", dependencies: ["Swidux"]),
        .target(name: "SwiduxDevPaywallUI", dependencies: ["SwiduxPaywall"]),
        .target(name: "SwiduxPersistence", dependencies: ["Swidux", "SwiduxMacros"]),
        .target(name: "SwiduxCloudKitSync", dependencies: ["SwiduxPersistence"]),
        .testTarget(name: "SwiduxTests", dependencies: ["Swidux"]),
        .testTarget(name: "SwiduxAnalyticsTests", dependencies: ["Swidux", "SwiduxAnalytics"]),
        .testTarget(name: "SwiduxFeatureFlagsTests", dependencies: ["Swidux", "SwiduxFeatureFlags"]),
        .testTarget(name: "SwiduxKillswitchTests", dependencies: ["Swidux", "SwiduxKillswitch"]),
        .testTarget(
            name: "SwiduxMacrosTests",
            dependencies: [
                "SwiduxMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(name: "SwiduxParentalGateTests", dependencies: ["Swidux", "SwiduxParentalGate"]),
        .testTarget(name: "SwiduxPaywallTests", dependencies: ["Swidux", "SwiduxPaywall"]),
        .testTarget(
            name: "SwiduxDevPaywallUITests",
            dependencies: ["SwiduxPaywall", "SwiduxDevPaywallUI"]
        ),
        .testTarget(name: "SwiduxPersistenceTests", dependencies: ["Swidux", "SwiduxPersistence"]),
        .testTarget(
            name: "SwiduxCloudKitSyncTests",
            dependencies: ["Swidux", "SwiduxPersistence", "SwiduxCloudKitSync"]
        ),
    ]
)

// MARK: - Dev-only tooling
//
// Dev-only tooling (the Persnoop swift-format linter and the DocC command plugin) must not
// leak into downstream consumers' dependency graphs. A build-tool plugin attached to a
// shipping target follows that target into every consumer — as a forced "trust and enable"
// prompt in Xcode, not merely a wasted checkout. SwiftPM has no first-class dev
// dependencies, so gate them on a gitignored `.dev-tooling` sentinel, present only in this
// package's own working clone (and created as a CI step, before the first resolve).
//
// `#filePath` anchors the lookup to this manifest's directory, independent of the current
// working directory. Attaching the plugin here, after the package is constructed, keeps the
// target list above free of gating noise.
//
// Toggling the sentinel on an already-evaluated package requires `swift package purge-cache`:
// SwiftPM caches the evaluated manifest keyed on its source text alone, so a gate that reads
// an external file is invisible to that cache key.

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let devSentinel = packageDir.appendingPathComponent(".dev-tooling").path

if FileManager.default.fileExists(atPath: devSentinel) {
    package.dependencies += [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.5.0"),
        .package(url: "https://github.com/HeirloomLogic/Persnicket", from: "2.0.0"),
    ]
    for target in package.targets where target.type != .plugin && target.type != .binary {
        target.plugins = (target.plugins ?? []) + [.plugin(name: "Persnoop", package: "Persnicket")]
    }
}
