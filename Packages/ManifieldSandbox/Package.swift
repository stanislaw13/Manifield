// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ManifieldSandbox",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "ManifieldSandbox", targets: ["ManifieldSandbox"])
    ],
    targets: [
        .target(name: "ManifieldSandbox"),
        .testTarget(name: "ManifieldSandboxTests", dependencies: ["ManifieldSandbox"])
    ]
)
