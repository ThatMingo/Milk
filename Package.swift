// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Milk",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Milk", targets: ["Milk"])],
    dependencies: [.package(path:"Packages/MilkExtensionKit"), .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.2")],
    targets: [
        .target(name: "MilkLayout"),
        .target(name: "MilkExtensionHost", dependencies: [.product(name:"MilkExtensionKit",package:"MilkExtensionKit"), "MilkPTY"]),
        .target(name: "MilkPTY"),
        .target(name: "MilkArchive", linkerSettings: [.linkedLibrary("archive")]),
        .executableTarget(name: "Milk", dependencies: ["MilkLayout", "MilkPTY", "MilkArchive", .product(name:"MilkExtensionKit",package:"MilkExtensionKit"), "MilkExtensionHost", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "MilkExtensionTests", dependencies: ["MilkExtensionHost", .product(name:"MilkExtensionKit",package:"MilkExtensionKit"), "MilkLayout"]),
        .testTarget(name: "MilkLayoutTests", dependencies: ["MilkLayout"]),
        .testTarget(name: "MilkWorkspaceTests", dependencies: ["Milk"])
    ],
    swiftLanguageModes: [.v5]
)
