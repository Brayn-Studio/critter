// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Critter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CritterCore", targets: ["CritterCore"]),
        .executable(name: "critter-hook", targets: ["critter-hook"]),
        .executable(name: "Critter", targets: ["CritterApp"]),
    ],
    targets: [
        .target(name: "CritterCore"),
        .executableTarget(name: "critter-hook", dependencies: ["CritterCore"]),
        .executableTarget(name: "CritterApp", dependencies: ["CritterCore"]),
        .testTarget(name: "CritterCoreTests", dependencies: ["CritterCore"]),
        .testTarget(name: "CritterHookTests", dependencies: ["critter-hook", "CritterCore"]),
    ]
)
