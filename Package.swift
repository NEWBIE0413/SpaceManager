// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpaceManager",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "CPty",
            path: "Sources/CPty"
        ),
        .executableTarget(
            name: "SpaceManager",
            dependencies: [
                "CPty"
            ],
            path: "Sources/SpaceManager",
            resources: [
                .copy("Terminal/Resources")
            ]
        ),
        .testTarget(
            name: "SpaceManagerTests",
            dependencies: ["SpaceManager"],
            path: "Tests/SpaceManagerTests"
        )
    ]
)
