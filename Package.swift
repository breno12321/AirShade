// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AirShade", platforms: [.macOS(.v14)], products: [
    .executable(name: "AirShade", targets: ["AirShade"])
], targets: [
    .target(name: "AirShadeCore"),
    .executableTarget(name: "AirShade", dependencies: ["AirShadeCore"]),
    .testTarget(name: "AirShadeCoreTests", dependencies: ["AirShadeCore"])
])
