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
        .target(name: "Strybok", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(name: "StrybokTesting", dependencies: ["Strybok"]),
        .testTarget(
            name: "StrybokTests",
            dependencies: ["Strybok", "StrybokTesting"],
            // The shared test vectors of the SDK contract, a byte-identical copy.
            resources: [.copy("Fixtures/parameter-links-vectors.json")]
        ),
    ]
)
