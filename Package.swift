// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OmniTools",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "OmniTools", targets: ["OmniTools"]),
        // Il motore comune, usato anche dall'app per iPhone (cartella iOS/).
        .library(name: "UtilityCore", targets: ["UtilityCore"]),
    ],
    targets: [
        // Logica pura (scansione, regole, duplicati, pulizia): niente interfaccia, testabile.
        .target(name: "UtilityCore"),
        // App con finestra (SwiftUI).
        .executableTarget(name: "OmniTools", dependencies: ["UtilityCore"],
                          resources: [.process("Resources")]),
        .testTarget(name: "UtilityCoreTests", dependencies: ["UtilityCore"]),
    ]
)
