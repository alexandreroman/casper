// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Casper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CasperCore", targets: ["CasperCore"]),
    ],
    targets: [
        .target(name: "CasperCore"),
        .testTarget(name: "CasperCoreTests", dependencies: ["CasperCore"]),
    ]
)
