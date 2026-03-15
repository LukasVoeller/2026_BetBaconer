// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetBaconer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "BetBaconer", targets: ["BetBaconer"]),
    ],
    targets: [
        .executableTarget(
            name: "BetBaconer",
            path: "Sources",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "BetBaconerTests",
            dependencies: ["BetBaconer"],
            path: "Tests/BetBaconerTests"
        ),
    ]
)
