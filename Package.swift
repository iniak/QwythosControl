// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QwythosControl",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "QwythosCore", targets: ["QwythosCore"]),
        .executable(name: "QwythosControlApp", targets: ["QwythosControlApp"]),
    ],
    targets: [
        .target(name: "QwythosCore"),
        .executableTarget(
            name: "QwythosControlApp",
            dependencies: ["QwythosCore"]
        ),
        .testTarget(
            name: "QwythosCoreTests",
            dependencies: ["QwythosCore"]
        ),
    ]
)
