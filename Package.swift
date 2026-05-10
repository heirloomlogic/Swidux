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
        .library(name: "SwiduxKillswitch", targets: ["SwiduxKillswitch"]),
        .library(name: "SwiduxParentalGate", targets: ["SwiduxParentalGate"]),
        .library(name: "SwiduxPaywall", targets: ["SwiduxPaywall"]),
        .library(name: "SwiduxAnalytics", targets: ["SwiduxAnalytics"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.5.0"),
        .package(url: "https://github.com/HeirloomLogic/SwiftFormatPlugin", from: "1.6.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        .macro(
            name: "SwiduxMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
        .target(
            name: "Swidux",
            dependencies: ["SwiduxMacros"],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
        .target(
            name: "SwiduxKillswitch",
            dependencies: ["Swidux"],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
        .target(
            name: "SwiduxParentalGate",
            dependencies: ["Swidux"],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
        .target(
            name: "SwiduxPaywall",
            dependencies: ["Swidux"],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
        .target(
            name: "SwiduxAnalytics",
            dependencies: ["Swidux"],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
        .testTarget(
            name: "SwiduxTests",
            dependencies: ["Swidux"],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
        .testTarget(
            name: "SwiduxKillswitchTests",
            dependencies: ["Swidux", "SwiduxKillswitch"],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
        .testTarget(
            name: "SwiduxParentalGateTests",
            dependencies: ["Swidux", "SwiduxParentalGate"],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
        .testTarget(
            name: "SwiduxPaywallTests",
            dependencies: ["Swidux", "SwiduxPaywall"],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
        .testTarget(
            name: "SwiduxAnalyticsTests",
            dependencies: ["Swidux", "SwiduxAnalytics"],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
        .testTarget(
            name: "SwiduxMacrosTests",
            dependencies: [
                "SwiduxMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            plugins: [
                .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
            ]
        ),
    ]
)
