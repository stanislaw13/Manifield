// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ManifieldAgents",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "ManifieldAgents", targets: ["ManifieldAgents"])
    ],
    dependencies: [
        .package(path: "../ManifieldCore"),
        .package(path: "../ManifieldSandbox")
    ],
    targets: [
        .target(
            name: "ManifieldAgents",
            dependencies: [
                .product(name: "ManifieldCore", package: "ManifieldCore"),
                .product(name: "ManifieldSandbox", package: "ManifieldSandbox")
            ],
            resources: [.copy("Prompts")]
        ),
        .testTarget(name: "ManifieldAgentsTests", dependencies: ["ManifieldAgents"])
    ]
)
