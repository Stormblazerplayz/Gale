// swift-tools-version:5.9
import PackageDescription

// GaleKit: everything in Gale that doesn't need a screen.
// It only uses Foundation, so it builds and tests on macOS, iOS and Linux.
let package = Package(
    name: "GaleKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "GaleFormat", targets: ["GaleFormat"]),
        .library(name: "GaleCore", targets: ["GaleCore"]),
        .library(name: "GaleSync", targets: ["GaleSync"])
    ],
    targets: [
        // The file format: projects, layers, frames, strokes, loops, stash, movie tracks.
        .target(name: "GaleFormat", path: "Sources/GaleFormat"),
        // Drawing and animation engine: stabilizer, stroke shapes, onion skin, playback,
        // loops, smart stash, motion blur, hair sway, paint bucket, undo.
        .target(name: "GaleCore", dependencies: ["GaleFormat"], path: "Sources/GaleCore"),
        // Live sync: clock, last-writer-wins replica, project <-> objects, pairing messages.
        .target(name: "GaleSync", dependencies: ["GaleFormat"], path: "Sources/GaleSync"),
        .testTarget(name: "GaleFormatTests", dependencies: ["GaleFormat"], path: "Tests/GaleFormatTests"),
        .testTarget(name: "GaleCoreTests", dependencies: ["GaleCore", "GaleFormat"], path: "Tests/GaleCoreTests"),
        .testTarget(name: "GaleSyncTests", dependencies: ["GaleSync", "GaleFormat"], path: "Tests/GaleSyncTests")
    ]
)
