// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CairnCompanion",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CairnCore", targets: ["CairnCore"]),
        .library(name: "CairnRuntime", targets: ["CairnRuntime"]),
    ],
    targets: [
        // Wire format, validity mapping, and staleness rules. No UI, no live radio or GPS,
        // so it builds and tests on macOS with `swift test`.
        .target(name: "CairnCore"),
        .testTarget(name: "CairnCoreTests", dependencies: ["CairnCore"]),
        // CoreBluetooth central, Core Location stream, driving session, SwiftUI screen.
        // Needs real radios and GPS to exercise; unit-testable logic lives in CairnCore.
        .target(name: "CairnRuntime", dependencies: ["CairnCore"]),
    ]
)
