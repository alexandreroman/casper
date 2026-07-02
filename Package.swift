// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Casper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CasperCore", targets: ["CasperCore"]),
        .library(name: "CasperGit", targets: ["CasperGit"]),
        .library(name: "CasperAgents", targets: ["CasperAgents"]),
        .library(name: "CasperCLI", targets: ["CasperCLI"]),
        .library(name: "CasperGhostty", targets: ["CasperGhostty"]),
        .executable(name: "casper", targets: ["casper"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/Lakr233/libghostty-spm.git",
            exact: "1.2.8"
        ),
    ],
    targets: [
        .systemLibrary(
            name: "Clibgit2",
            pkgConfig: "libgit2",
            providers: [.brew(["libgit2"])]
        ),
        .target(name: "CasperGit", dependencies: ["Clibgit2"]),
        .target(name: "CasperCore", dependencies: ["CasperGit"]),
        .target(name: "CasperAgents", dependencies: ["CasperCore"]),
        .target(
            name: "CasperGhostty",
            dependencies: [
                "CasperCore",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "CasperCLI",
            dependencies: [
                "CasperCore",
                "CasperAgents",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "casper", dependencies: ["CasperCLI", "CasperGhostty"]),
        .testTarget(
            name: "CasperGitTests",
            dependencies: ["CasperGit", "Clibgit2"]
        ),
        .testTarget(
            name: "CasperCoreTests",
            dependencies: ["CasperCore", "Clibgit2"]
        ),
        .testTarget(
            name: "CasperAgentsTests",
            dependencies: ["CasperAgents", "CasperCore"]
        ),
        .testTarget(
            name: "CasperCLITests",
            dependencies: ["CasperCLI", "CasperAgents", "CasperCore"]
        ),
        .testTarget(
            name: "CasperGhosttyTests",
            dependencies: ["CasperGhostty"]
        ),
    ]
)
