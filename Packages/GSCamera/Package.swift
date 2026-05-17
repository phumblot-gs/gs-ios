// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSCamera",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "GSCamera",
            targets: ["GSCamera"]
        )
    ],
    dependencies: [
        .package(path: "../GSCore")
    ],
    targets: [
        .target(
            name: "GSCamera",
            dependencies: ["GSCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "GSCameraTests",
            dependencies: ["GSCamera"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
