// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CairnCompanion",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CairnCore", targets: ["CairnCore"]),
        .library(name: "CairnRuntime", targets: ["CairnRuntime"]),
    ],
    dependencies: [
        .package(url: "https://github.com/duckdb/duckdb-swift", from: "1.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Wire format, validity mapping, and staleness rules. No UI, no live radio or GPS,
        // so it builds and tests on macOS with `swift test`.
        .target(name: "CairnCore"),
        .testTarget(name: "CairnCoreTests", dependencies: ["CairnCore"]),
        // CoreBluetooth central, Core Location stream, driving session, SwiftUI screen.
        // Needs real radios and GPS to exercise; unit-testable logic lives in CairnCore.
        .target(name: "CairnRuntime", dependencies: [
            "CairnCore",
            .product(name: "DuckDB", package: "duckdb-swift"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
    ]
)
