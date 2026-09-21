// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoherenceGraph",
    // Only platforms CI actually builds are declared. The Linux job builds
    // `CoherenceGraph`; the macOS job and the demo app build both modules for
    // an iOS Simulator destination. Nothing here claims watchOS/tvOS support
    // that no job has ever compiled.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoherenceGraph", targets: ["CoherenceGraph"]),
        .library(name: "CoherenceGraphUI", targets: ["CoherenceGraphUI"]),
    ],
    targets: [
        .target(name: "CoherenceGraph"),
        .target(name: "CoherenceGraphUI", dependencies: ["CoherenceGraph"]),
        .testTarget(name: "CoherenceGraphTests", dependencies: ["CoherenceGraph"]),
    ]
)
