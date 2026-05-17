// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSLogistics",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "GSLogistics",
            targets: ["GSLogistics"]
        )
    ],
    dependencies: [
        .package(path: "../GSCore"),
        .package(path: "../GSAPIClient")
    ],
    targets: [
        .target(
            name: "GSLogistics",
            dependencies: ["GSCore", "GSAPIClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "GSLogisticsTests",
            dependencies: ["GSLogistics"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
