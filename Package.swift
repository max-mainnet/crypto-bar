// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "BTCPrice",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "BTCPrice", targets: ["BTCPrice"])],
    targets: [
        .target(name: "BTCPriceCore"),
        .executableTarget(name: "BTCPrice", dependencies: ["BTCPriceCore"]),
        .testTarget(name: "BTCPriceCoreTests", dependencies: ["BTCPriceCore"])
    ]
)
