// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Critter",
    platforms: [.macOS(.v14), .iOS("17.2")],
    products: [
        .library(name: "CritterKit", targets: ["CritterKit"]),
        .library(name: "CritterCore", targets: ["CritterCore"]),
        .executable(name: "critter-hook", targets: ["critter-hook"]),
        .executable(name: "Critter", targets: ["CritterApp"]),
    ],
    targets: [
        .target(name: "CritterKit"),
        .target(name: "CritterCore", dependencies: ["CritterKit"]),
        .executableTarget(name: "critter-hook", dependencies: ["CritterCore"]),
        .executableTarget(name: "CritterApp", dependencies: ["CritterCore"]),
        .executableTarget(name: "critter-bridge-client", dependencies: ["CritterCore"]),
        .testTarget(name: "CritterKitTests", dependencies: ["CritterKit"]),
        .testTarget(name: "CritterCoreTests", dependencies: ["CritterCore"]),
        .testTarget(name: "CritterHookTests", dependencies: ["critter-hook", "CritterCore"]),
    ]
)
