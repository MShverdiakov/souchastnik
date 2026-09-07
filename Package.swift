// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SouchastnikCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SouchastnikCore", targets: ["SouchastnikCore"])],
    targets: [
        .target(name: "SouchastnikCore"),
        .testTarget(name: "SouchastnikCoreTests", dependencies: ["SouchastnikCore"])
    ]
)
