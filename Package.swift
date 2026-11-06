// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "termquilt",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "termquilt", targets: ["termquilt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Pure layout logic and orchestration. No AppKit, so all of it is unit tested.
        .target(name: "TermquiltCore"),
        // Thin adapters onto macOS: screens, window list, Terminal.app, hotkeys, launchd.
        .target(name: "TermquiltMac", dependencies: ["TermquiltCore"]),
        .executableTarget(
            name: "termquilt",
            dependencies: [
                "TermquiltCore",
                "TermquiltMac",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "TermquiltCoreTests", dependencies: ["TermquiltCore"]),
    ]
)
