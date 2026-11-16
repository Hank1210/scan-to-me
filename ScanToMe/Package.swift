// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ScanToMe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"]),
        .executable(name: "ScanToMeApp", targets: ["ScanToMeApp"]),
    ],
    targets: [
        // Die gesamte Logik, testbar und ohne Oberfläche.
        // FoundationModels (Apples Sprachmodell, M7) gibt es erst ab macOS 26: schwach binden, damit die App
        // auch auf älteren Systemen startet. Genutzt wird es nur hinter `#available(macOS 27, *)`.
        .target(name: "ScanCore", linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]),
        // SwiftUI-App, bleibt dünn.
        .executableTarget(name: "ScanToMeApp", dependencies: ["ScanCore"]),
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"]),
    ]
)
