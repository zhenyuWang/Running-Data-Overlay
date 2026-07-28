// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RunOverlay",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RunOverlayCore", targets: ["RunOverlayCore"])
    ],
    targets: [
        .target(
            name: "RunOverlayCore",
            path: "Sources/RunningDataOverlay",
            exclude: ["RunningDataOverlayApp.swift"],
            sources: ["FitParser.swift", "RunOverlayCore.swift"]
        ),
        .testTarget(
            name: "RunOverlayCoreTests",
            dependencies: ["RunOverlayCore"],
            path: "Tests",
            exclude: ["FitParserSmokeTest.swift"],
            sources: ["RunOverlayCoreTests.swift"]
        )
    ]
)
