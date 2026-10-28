// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Nook",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Nook", targets: ["Nook"]),
    ],
    targets: [
        // Pure model: layouts, split trees, solver, screen state. No AppKit.
        .target(
            name: "NookKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Nook",
            dependencies: ["NookKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // A window-opening test app for scripts/e2e.swift.
        .executableTarget(
            name: "NookFixture",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NookKitTests",
            dependencies: ["NookKit"]
        ),
    ]
)
