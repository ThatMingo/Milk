// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MilkExtensionKit",
    platforms: [.macOS("26.0")],
    products: [.library(name:"MilkExtensionKit",type:.dynamic,targets:["MilkExtensionKit"])],
    targets: [.target(name:"MilkExtensionKit",swiftSettings:[.unsafeFlags(["-enable-library-evolution","-emit-module-interface"])])],
    swiftLanguageModes: [.v5]
)
