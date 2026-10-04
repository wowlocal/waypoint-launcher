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
        ]),
        .executableTarget(name: "waypoint-cli", dependencies: ["WaypointCore"]),
        .testTarget(name: "WaypointCoreTests", dependencies: ["WaypointCore"]),
    ]
)
