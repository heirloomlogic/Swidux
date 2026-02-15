// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Swidux",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "Swidux",
            targets: ["Swidux"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/HeirloomLogic/SwiftFormatPlugin", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "Swidux",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("DefaultIsolationMainActor"),
            ],
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
    ]
)
