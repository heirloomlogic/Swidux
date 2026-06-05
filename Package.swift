// swift-tools-version: 6.2

import CompilerPluginSupport
import Foundation
import PackageDescription

// Dev-only tooling (Persnoop swift-format linter + the DocC command plugin) must not
// leak into downstream consumers' dependency graphs. SwiftPM has no first-class
// dev-dependencies, so gate them on a gitignored `.dev-tooling` sentinel, present only
// in this package's own working clone (and created as a CI step). `#filePath` anchors
// the lookup to this manifest's directory, independent of the current working directory.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let devSentinel = packageDir.appendingPathComponent(".dev-tooling").path
let isDevBuild = FileManager.default.fileExists(atPath: devSentinel)

let devDependencies: [Package.Dependency] =
    isDevBuild
    ? [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.5.0"),
        .package(url: "https://github.com/HeirloomLogic/Persnicket", from: "2.0.0"),
    ]
    : []

let devPlugins: [Target.PluginUsage] =
    isDevBuild ? [.plugin(name: "Persnoop", package: "Persnicket")] : []

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
    dependencies: devDependencies + [
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        .macro(
            name: "SwiduxMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ],
            plugins: devPlugins
        ),
        .target(
            name: "Swidux",
            dependencies: ["SwiduxMacros"],
            plugins: devPlugins
        ),
        .target(
            name: "SwiduxAnalytics",
            dependencies: ["Swidux"],
            plugins: devPlugins
        ),
        .target(
            name: "SwiduxFeatureFlags",
            dependencies: ["Swidux"],
            plugins: devPlugins
        ),
        .target(
            name: "SwiduxKillswitch",
            dependencies: ["Swidux"],
            plugins: devPlugins
        ),
        .target(
            name: "SwiduxParentalGate",
            dependencies: ["Swidux"],
            plugins: devPlugins
        ),
        .target(
            name: "SwiduxPaywall",
            dependencies: ["Swidux"],
            plugins: devPlugins
        ),
        .target(
            name: "SwiduxDevPaywallUI",
            dependencies: ["SwiduxPaywall"],
            plugins: devPlugins
        ),
        .target(
            name: "SwiduxPersistence",
            dependencies: ["Swidux", "SwiduxMacros"],
            plugins: devPlugins
        ),
        .target(
            name: "SwiduxCloudKitSync",
            dependencies: ["SwiduxPersistence"],
            plugins: devPlugins
        ),
        .testTarget(
            name: "SwiduxTests",
            dependencies: ["Swidux"],
            plugins: devPlugins
        ),
        .testTarget(
            name: "SwiduxAnalyticsTests",
            dependencies: ["Swidux", "SwiduxAnalytics"],
            plugins: devPlugins
        ),
        .testTarget(
            name: "SwiduxFeatureFlagsTests",
            dependencies: ["Swidux", "SwiduxFeatureFlags"],
            plugins: devPlugins
        ),
        .testTarget(
            name: "SwiduxKillswitchTests",
            dependencies: ["Swidux", "SwiduxKillswitch"],
            plugins: devPlugins
        ),
        .testTarget(
            name: "SwiduxMacrosTests",
            dependencies: [
                "SwiduxMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            plugins: devPlugins
        ),
        .testTarget(
            name: "SwiduxParentalGateTests",
            dependencies: ["Swidux", "SwiduxParentalGate"],
            plugins: devPlugins
        ),
        .testTarget(
            name: "SwiduxPaywallTests",
            dependencies: ["Swidux", "SwiduxPaywall"],
            plugins: devPlugins
        ),
        .testTarget(
            name: "SwiduxDevPaywallUITests",
            dependencies: ["SwiduxPaywall", "SwiduxDevPaywallUI"],
            plugins: devPlugins
        ),
        .testTarget(
            name: "SwiduxPersistenceTests",
            dependencies: ["Swidux", "SwiduxPersistence"],
            plugins: devPlugins
        ),
        .testTarget(
            name: "SwiduxCloudKitSyncTests",
            dependencies: ["Swidux", "SwiduxPersistence", "SwiduxCloudKitSync"],
            plugins: devPlugins
        ),
    ]
)
