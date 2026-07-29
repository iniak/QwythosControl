// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QwythosControl",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "QwythosCore", targets: ["QwythosCore"]),
        .library(name: "QwythosDeployment", targets: ["QwythosDeployment"]),
        .executable(name: "QwythosControlApp", targets: ["QwythosControlApp"]),
    ],
    targets: [
        .target(name: "QwythosCore"),
        .target(
            name: "QwythosDeployment",
            dependencies: ["QwythosCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "QwythosControlApp",
            dependencies: ["QwythosCore", "QwythosDeployment"]
        ),
        .testTarget(
            name: "QwythosCoreTests",
            dependencies: ["QwythosCore"]
        ),
        .testTarget(
            name: "QwythosDeploymentTests",
            dependencies: ["QwythosDeployment"]
        ),
        .testTarget(
            name: "QwythosControlAppTests",
            dependencies: ["QwythosControlApp", "QwythosDeployment"]
        ),
    ]
)
