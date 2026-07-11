// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "fxpa",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "fxpa", targets: ["fxpa"]),
        .library(name: "FXPAKit", targets: ["FXPAKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "fxpa",
            dependencies: [
                "FXPAKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "FXPAKit",
            dependencies: [
                "CClang",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [
                .copy("Resources/templates"),
                .copy("Resources/config"),
            ]
        ),
        .target(name: "CClang"),
        .testTarget(
            name: "FXPAKitTests",
            dependencies: ["FXPAKit"]
        ),
    ]
)
