// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenClicky",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenClickyKit", targets: ["OpenClickyKit"]),
        .executable(name: "openclicky", targets: ["openclicky"]),
        .executable(name: "OpenClickyApp", targets: ["OpenClickyApp"]),
    ],
    targets: [
        .target(
            name: "OpenClickyKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "openclicky",
            dependencies: ["OpenClickyKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "OpenClickyApp",
            dependencies: ["OpenClickyKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OpenClickyKitTests",
            dependencies: ["OpenClickyKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
