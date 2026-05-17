// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSLiDAR",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "GSLiDAR",
            targets: ["GSLiDAR"]
        )
    ],
    dependencies: [
        .package(path: "../GSCore")
    ],
    targets: [
        .target(
            name: "GSLiDAR",
            dependencies: ["GSCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "GSLiDARTests",
            dependencies: ["GSLiDAR"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
