// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NotchHost",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "NotchHost", targets: ["NotchHost"]),
    ],
    dependencies: [
        .package(path: "../NotchKit"),
    ],
    targets: [
        .executableTarget(
            name: "NotchHost",
            dependencies: ["NotchKit"]
        ),
        .testTarget(
            name: "NotchHostTests",
            dependencies: ["NotchHost"]
        ),
    ]
)
