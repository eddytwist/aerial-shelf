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
    targets: [
        .target(name: "AerialCore"),
        .executableTarget(name: "aerialctl", dependencies: ["AerialCore"]),
        .executableTarget(
            name: "AerialistApp",
            dependencies: ["AerialCore"],
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "AerialCoreTests",
            dependencies: ["AerialCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
