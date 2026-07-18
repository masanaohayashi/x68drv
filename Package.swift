// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "X68Core",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "X68Core", targets: ["X68Core"]),
    ],
    targets: [
        .target(
            name: "X68Core",
            path: "Sources/X68Core"
        ),
        .testTarget(
            name: "X68CoreTests",
            dependencies: ["X68Core"],
            path: "Tests/X68CoreTests"
        ),
    ]
)
