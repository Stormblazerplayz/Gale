// swift-tools-version:5.9
import PackageDescription

// GaleLearn: Gale's built-in courses. Course data, the lesson engine, scoring, narration scripts,
// progress, and the bridge that turns an "animate it" step into a real Gale project.
// Foundation and GaleFormat only (no UI), so it builds and tests on macOS, iOS and Linux.
// The SwiftUI screens live in the app target (Gale/Learn).
let package = Package(
    name: "GaleLearn",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "GaleLearn", targets: ["GaleLearn"])
    ],
    dependencies: [
        .package(path: "../GaleKit")
    ],
    targets: [
        .target(
            name: "GaleLearn",
            dependencies: [.product(name: "GaleFormat", package: "GaleKit")],
            path: "Sources/GaleLearn",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "GaleLearnTests",
            dependencies: ["GaleLearn", .product(name: "GaleFormat", package: "GaleKit")],
            path: "Tests/GaleLearnTests"
        )
    ]
)
