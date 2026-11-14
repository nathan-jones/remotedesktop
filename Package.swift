// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenShareKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ScreenShareKit", targets: ["ScreenShareKit"]),
    ],
    targets: [
        .target(
            name: "ScreenShareKit",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(name: "ssprobe", dependencies: ["ScreenShareKit"]),
        .executableTarget(name: "ssgateway", dependencies: ["ScreenShareKit"]),
        .executableTarget(name: "sscamera", dependencies: ["ScreenShareKit"]),
        .testTarget(name: "ScreenShareKitTests", dependencies: ["ScreenShareKit"]),
        .testTarget(name: "sscameraTests", dependencies: ["sscamera"]),
    ]
)
