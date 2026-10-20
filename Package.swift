// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OmniTools",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OmniTools", targets: ["OmniTools"]),
    ],
    targets: [
        // Logica pura (scansione, regole, duplicati, pulizia): niente interfaccia, testabile.
        .target(name: "UtilityCore"),
        // App con finestra (SwiftUI).
        .executableTarget(name: "OmniTools", dependencies: ["UtilityCore"]),
        .testTarget(name: "UtilityCoreTests", dependencies: ["UtilityCore"]),
    ]
)
