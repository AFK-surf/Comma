// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CommaCore",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v14)],
    products: [.library(name: "CommaCore", targets: ["CommaCore"])],
    targets: [
        .target(name: "CommaCore"),
        .testTarget(name: "CommaCoreTests", dependencies: ["CommaCore"])
    ]
)
