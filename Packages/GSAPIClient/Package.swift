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
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.2")
    ],
    targets: [
        .target(
            name: "GSAPIClient",
            dependencies: [
                "GSCore",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession")
            ],
            // openapi.yaml + openapi-generator-config.yaml in Sources/ are picked
            // up automatically by the OpenAPIGenerator build plugin. The raw
            // swagger.json is kept alongside as a reference but not consumed.
            exclude: [
                "swagger.json"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
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
