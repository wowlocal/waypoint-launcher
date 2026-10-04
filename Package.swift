// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Waypoint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Waypoint", targets: ["Waypoint"]),
        .executable(name: "waypoint-cli", targets: ["waypoint-cli"]),
    ],
    targets: [
        .target(name: "WaypointCore"),
        .executableTarget(name: "Waypoint", dependencies: ["WaypointCore"]),
        .executableTarget(name: "waypoint-cli", dependencies: ["WaypointCore"]),
        .testTarget(name: "WaypointCoreTests", dependencies: ["WaypointCore"]),
    ]
)
