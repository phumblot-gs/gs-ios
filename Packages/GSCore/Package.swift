// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "GSCore",
            targets: ["GSCore"]
        )
    ],
    targets: [
        .target(
            name: "GSCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "GSCoreTests",
            dependencies: ["GSCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
