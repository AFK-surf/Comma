// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NotchKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "NotchKit",
            targets: ["NotchKit"]
        ),
    ],
    targets: [
        .target(
            name: "NotchKit"
        ),
    ]
)
