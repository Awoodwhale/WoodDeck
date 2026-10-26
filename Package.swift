// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WoodDeck",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0")
    ],
    targets: [
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            sources: ["zstd-src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("zstd-src"),
                .headerSearchPath("zstd-src/common"),
                .headerSearchPath("zstd-src/decompress")
            ]
        ),
        .executableTarget(
            name: "WoodDeck",
            dependencies: [
                "CZstd",
                .product(name: "Yams", package: "Yams"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/WoodDeck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
