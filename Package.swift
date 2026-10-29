// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Milk", platforms: [.macOS("26.0")],
    products: [
        .library(name: "MilkCore", targets: ["MilkCore"]),
        .library(name: "MilkKit", targets: ["MilkKit"]),
        .executable(name: "MilkProbe", targets: ["MilkProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", exact: "0.14.2"),
        .package(url: "https://github.com/ChimeHQ/JSONRPC", exact: "0.9.2"),
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.9.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "MilkCore", resources: [.copy("Resources")]),
        .target(name: "MilkKit", dependencies: [
            "MilkCore", .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
            .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
            .product(name: "JSONRPC", package: "JSONRPC"),
            .product(name: "Markdown", package: "swift-markdown"),
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "Sparkle", package: "Sparkle")
        ]),
        .executableTarget(name: "MilkProbe", dependencies: ["MilkCore"]),
        .testTarget(name: "MilkCoreTests", dependencies: ["MilkCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MilkKitTests", dependencies: ["MilkKit"])
    ]
)
