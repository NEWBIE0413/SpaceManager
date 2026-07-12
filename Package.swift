// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpaceManager",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "CPty",
            path: "Sources/CPty"
        ),
        .executableTarget(
            name: "SpaceManager",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
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
