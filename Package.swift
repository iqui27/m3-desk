// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "M3Desk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "M3Desk", targets: ["M3Desk"])],
    targets: [
        .target(name: "M3DeskCore", path: "Sources/M3DeskCore"),
        .executableTarget(name: "M3DeskSmoke", dependencies: ["M3DeskCore"], path: "Sources/M3DeskSmoke"),
        .testTarget(name: "M3DeskCoreTests", dependencies: ["M3DeskCore"], path: "Tests/M3DeskCoreTests"),
        .executableTarget(name: "M3Desk", dependencies: ["M3DeskCore"], path: "Sources/M3Desk", swiftSettings: [
            .unsafeFlags(["-Xfrontend", "-warn-long-expression-type-checking=100", "-Xfrontend", "-warn-long-function-bodies=100"])
        ]),
        .testTarget(name: "M3DeskTests", dependencies: ["M3Desk", "M3DeskCore"], path: "Tests/M3DeskTests")
    ]
)
