// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "daylight-mirror",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MirrorEngine",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/MirrorEngine"
        ),
        .executableTarget(
            name: "daylight-mirror",
            dependencies: ["MirrorEngine"],
            path: "Sources/Mirror"
        ),
        .executableTarget(
            name: "DaylightMirror",
            dependencies: ["MirrorEngine"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "MirrorEngineTests",
            dependencies: ["MirrorEngine"],
            path: "Tests/MirrorEngineTests"
        )
    ]
)
