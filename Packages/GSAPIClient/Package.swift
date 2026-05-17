// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSAPIClient",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "GSAPIClient",
            targets: ["GSAPIClient"]
        )
    ],
    dependencies: [
        .package(path: "../GSCore"),
        // TODO: enable swift-openapi-generator once swagger.json → openapi.yaml pipeline is wired up.
        // .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        // .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        // .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "GSAPIClient",
            dependencies: [
                "GSCore"
                // TODO: add OpenAPIRuntime + OpenAPIURLSession once generator is enabled.
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "GSAPIClientTests",
            dependencies: ["GSAPIClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
