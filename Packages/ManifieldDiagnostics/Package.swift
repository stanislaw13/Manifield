// swift-tools-version:5.10
import PackageDescription

// A leaf package on purpose: it depends on nothing of Manifield's, so ManifieldCore,
// ManifieldAgents and ManifieldSandbox can each adopt the logger later without any of
// them pulling in a dependency cycle.
let package = Package(
    name: "ManifieldDiagnostics",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "ManifieldDiagnostics", targets: ["ManifieldDiagnostics"])
    ],
    targets: [
        .target(name: "ManifieldDiagnostics"),
        .testTarget(name: "ManifieldDiagnosticsTests", dependencies: ["ManifieldDiagnostics"])
    ]
)
