// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ManifieldCore",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "ManifieldCore", targets: ["ManifieldCore"])
    ],
    targets: [
        .target(
            name: "ManifieldCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "ManifieldCoreTests", dependencies: ["ManifieldCore"])
    ]
)
