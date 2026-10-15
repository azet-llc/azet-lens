// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MwoyeaCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MwoyeaCore", targets: ["MwoyeaCore"])],
    targets: [
        .target(name: "MwoyeaCore"),
        .testTarget(name: "MwoyeaCoreTests", dependencies: ["MwoyeaCore"]),
    ]
)
