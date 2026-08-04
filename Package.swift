// swift-tools-version:5.9
import PackageDescription

// MetroKit is the routing engine: pure Foundation, no UIKit, no CoreLocation.
// It lives inside the app folder so Xcode's synchronized group compiles it into
// the app target, and it is exposed as a package here so `swift test` can
// exercise the planner without booting a simulator.
let package = Package(
    name: "MetroKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MetroKit", targets: ["MetroKit"]),
    ],
    targets: [
        .target(
            name: "MetroKit",
            path: "BroadStreetCommute/MetroKit"
        ),
        .testTarget(
            name: "MetroKitTests",
            dependencies: ["MetroKit"],
            path: "Tests/MetroKitTests"
        ),
    ]
)
