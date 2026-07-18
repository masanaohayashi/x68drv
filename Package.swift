// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "X68Core",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "X68Core", targets: ["X68Core"]),
        .executable(name: "x68drv-tool", targets: ["x68drv-tool"]),
        .executable(name: "x68mount-helper", targets: ["x68mount-helper"]),
    ],
    targets: [
        .target(
            name: "X68Core",
            path: "Sources/X68Core"
        ),
        .executableTarget(
            name: "x68drv-tool",
            dependencies: ["X68Core"],
            path: "Sources/x68drv-tool"
        ),
        // C bridge to libfuse (symbols resolved at runtime via dlopen + dynamic_lookup)
        .target(
            name: "FuseBridge",
            path: "Sources/FuseBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("../../ThirdParty/fuse/include"),
                .define("FUSE_USE_VERSION", to: "26"),
                .define("_FILE_OFFSET_BITS", to: "64"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
            ]
        ),
        .executableTarget(
            name: "x68mount-helper",
            dependencies: ["X68Core", "FuseBridge"],
            path: "Sources/x68mount-helper"
        ),
        .testTarget(
            name: "X68CoreTests",
            dependencies: ["X68Core"],
            path: "Tests/X68CoreTests"
        ),
    ]
)
