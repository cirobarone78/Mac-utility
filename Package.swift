// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacUtility",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacUtility", targets: ["MacUtility"]),
    ],
    targets: [
        // Logica pura (scansione, regole, duplicati, pulizia): niente interfaccia, testabile.
        .target(name: "UtilityCore"),
        // App con finestra (SwiftUI).
        .executableTarget(name: "MacUtility", dependencies: ["UtilityCore"]),
        .testTarget(name: "UtilityCoreTests", dependencies: ["UtilityCore"]),
    ]
)
