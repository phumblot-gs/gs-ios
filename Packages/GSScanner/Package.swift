// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSScanner",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "GSScanner",
            targets: ["GSScanner"]
        )
    ],
    dependencies: [
        .package(path: "../GSCore")
    ],
    targets: [
        .target(
            name: "GSScanner",
            dependencies: ["GSCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "GSScannerTests",
            dependencies: ["GSScanner"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
