// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Casper",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
        // Pinned by revision, not by tag: upstream tags are mutable. This
        // revision is the 1.2.8 release, with the same tree as the commit the
        // tag first named, so the binary checksum and vendored header hold.
        .package(
            url: "https://github.com/Lakr233/libghostty-spm.git",
            revision: "2ef85df0292dc864a857d30963b943e5d5b8dc87"
        ),
        .package(
            url: "https://github.com/appstefan/HighlightSwift.git",
            from: "1.1.0"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            from: "2.9.6"
        ),
    ],
    targets: [
        .systemLibrary(
            name: "Clibgit2",
            pkgConfig: "libgit2",
            providers: [.brew(["libgit2"])]
        ),
        .target(name: "CSigbusGuard"),
        .target(name: "CasperGit", dependencies: ["Clibgit2", "CSigbusGuard"]),
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
            ]
        ),
        .target(
            name: "CasperUI",
            dependencies: [
                "CasperCore",
                "CasperGit",
                "CasperGhostty",
                "CasperAgents",
                .product(name: "HighlightSwift", package: "HighlightSwift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .target(
            name: "CasperCLI",
            dependencies: [
                "CasperCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "casper", dependencies: ["CasperCLI", "CasperUI"]),
        // Fixtures shared by the test targets, which cannot import one another. A
        // regular target, so `swift build -c release` compiles it too: no
        // `@testable import` here.
        .target(
            name: "CasperTestSupport",
            dependencies: ["CasperGit", "Clibgit2"],
            path: "Tests/CasperTestSupport"
        ),
        .testTarget(
            name: "CasperGitTests",
            dependencies: ["CasperGit", "Clibgit2", "CasperTestSupport"]
        ),
        .testTarget(
            name: "CasperCoreTests",
            dependencies: ["CasperCore", "CasperTestSupport"]
        ),
        .testTarget(
            name: "CasperAgentsTests",
            dependencies: ["CasperAgents"]
        ),
        .testTarget(
            name: "CasperCLITests",
            dependencies: ["CasperCLI", "CasperCore", "CasperTestSupport"]
        ),
        .testTarget(
            name: "CasperGhosttyTests",
            dependencies: ["CasperGhostty", "CasperTestSupport"]
        ),
        .testTarget(
            name: "CasperUITests",
            dependencies: [
                "CasperUI", "CasperCore", "CasperGhostty", "CasperAgents", "CasperGit", "Clibgit2",
                "CasperTestSupport",
            ]
        ),
    ]
)
