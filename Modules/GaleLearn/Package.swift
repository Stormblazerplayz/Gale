// swift-tools-version:5.9
import PackageDescription

// GaleLearn: Gale's built-in courses. Course data, the lesson engine, scoring and progress.
// Foundation only (no UI), so it builds and tests on macOS, iOS and Linux.
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
    targets: [
        .target(
            name: "GaleLearn",
            path: "Sources/GaleLearn",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "GaleLearnTests",
            dependencies: ["GaleLearn"],
            path: "Tests/GaleLearnTests"
        )
    ]
)
