// swift-tools-version: 6.2

import CompilerPluginSupport
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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.5.0"),
        .package(url: "https://github.com/HeirloomLogic/Persnicket", from: "2.0.0"),
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
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .target(
            name: "Swidux",
            dependencies: ["SwiduxMacros"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .target(
            name: "SwiduxAnalytics",
            dependencies: ["Swidux"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .target(
            name: "SwiduxFeatureFlags",
            dependencies: ["Swidux"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .target(
            name: "SwiduxKillswitch",
            dependencies: ["Swidux"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .target(
            name: "SwiduxParentalGate",
            dependencies: ["Swidux"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .target(
            name: "SwiduxPaywall",
            dependencies: ["Swidux"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .target(
            name: "SwiduxDevPaywallUI",
            dependencies: ["SwiduxPaywall"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .testTarget(
            name: "SwiduxTests",
            dependencies: ["Swidux"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .testTarget(
            name: "SwiduxAnalyticsTests",
            dependencies: ["Swidux", "SwiduxAnalytics"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .testTarget(
            name: "SwiduxFeatureFlagsTests",
            dependencies: ["Swidux", "SwiduxFeatureFlags"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .testTarget(
            name: "SwiduxKillswitchTests",
            dependencies: ["Swidux", "SwiduxKillswitch"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .testTarget(
            name: "SwiduxMacrosTests",
            dependencies: [
                "SwiduxMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .testTarget(
            name: "SwiduxParentalGateTests",
            dependencies: ["Swidux", "SwiduxParentalGate"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .testTarget(
            name: "SwiduxPaywallTests",
            dependencies: ["Swidux", "SwiduxPaywall"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
        .testTarget(
            name: "SwiduxDevPaywallUITests",
            dependencies: ["SwiduxPaywall", "SwiduxDevPaywallUI"],
            plugins: [
                .plugin(name: "Persnoop", package: "Persnicket")
            ]
        ),
    ]
)
