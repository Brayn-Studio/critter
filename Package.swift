// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clawd",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClawdCore", targets: ["ClawdCore"]),
        .executable(name: "clawd-hook", targets: ["clawd-hook"]),
        .executable(name: "Clawd", targets: ["ClawdApp"]),
    ],
    targets: [
        .target(name: "ClawdCore"),
        .executableTarget(name: "clawd-hook", dependencies: ["ClawdCore"]),
        .executableTarget(name: "ClawdApp", dependencies: ["ClawdCore"]),
        .testTarget(name: "ClawdCoreTests", dependencies: ["ClawdCore"]),
        .testTarget(name: "ClawdHookTests", dependencies: ["clawd-hook", "ClawdCore"]),
    ]
)
