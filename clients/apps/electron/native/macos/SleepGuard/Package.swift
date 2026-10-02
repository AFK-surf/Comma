// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CommaSleepGuard",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "CommaSleepGuard", targets: ["CommaSleepGuard"]),
    ],
    targets: [
        .executableTarget(name: "CommaSleepGuard"),
    ]
)
