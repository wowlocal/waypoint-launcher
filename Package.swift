// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Waypoint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Waypoint", targets: ["Waypoint"]),
        .executable(name: "waypoint-cli", targets: ["waypoint-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
    ],
    targets: [
        .target(name: "WaypointCore"),
        .executableTarget(name: "Waypoint", dependencies: [
            "WaypointCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ], linkerSettings: [
            // SwiftPM (and Xcode building this package) links without telling
            // the linker which SDK it used, so the binary would claim the
            // deployment target's, 14.0, and macOS 26 and later draw such an
            // app in the old design: no Liquid Glass toolbar, square buttons.
            // Claim the macOS 26 SDK, the oldest that compiles this code.
            // Keep 14.0 in step with `platforms` above; raise 26.0 only after
            // checking the app against the newer SDK's behavior.
            .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"]),
        ]),
        .executableTarget(name: "waypoint-cli", dependencies: ["WaypointCore"]),
        .testTarget(name: "WaypointCoreTests", dependencies: ["WaypointCore"], resources: [.copy("Fixtures")]),
    ]
)
