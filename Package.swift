// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Aerialist",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AerialCore", targets: ["AerialCore"]),
        .executable(name: "aerialctl", targets: ["aerialctl"]),
        .executable(name: "AerialistApp", targets: ["AerialistApp"]),
    ],
    dependencies: [
        // In-app updates. Pinned: the release script uses this version's sign_update.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "AerialCore"),
        .executableTarget(name: "aerialctl", dependencies: ["AerialCore"]),
        .executableTarget(
            name: "AerialistApp",
            dependencies: ["AerialCore", .product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "AerialCoreTests",
            dependencies: ["AerialCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
