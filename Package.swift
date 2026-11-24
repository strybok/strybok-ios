// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Strybok",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "Strybok", targets: ["Strybok"]),
        // Test helpers for apps that integrate Strybok (fake link source, stub transport).
        .library(name: "StrybokTesting", targets: ["StrybokTesting"]),
    ],
    targets: [
        .target(name: "Strybok"),
        .target(name: "StrybokTesting", dependencies: ["Strybok"]),
        .testTarget(name: "StrybokTests", dependencies: ["Strybok", "StrybokTesting"]),
    ]
)
