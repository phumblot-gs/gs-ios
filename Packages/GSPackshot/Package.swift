// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSPackshot",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "GSPackshot",
            targets: ["GSPackshot"]
        )
    ],
    dependencies: [
        .package(path: "../GSCore"),
        .package(path: "../GSAPIClient")
    ],
    targets: [
        .target(
            name: "GSPackshot",
            dependencies: ["GSCore", "GSAPIClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "GSPackshotTests",
            dependencies: ["GSPackshot"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
