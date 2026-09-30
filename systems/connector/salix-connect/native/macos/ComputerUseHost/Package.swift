// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ComputerUseHost",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "CommaComputerUseDaemon", targets: ["CommaComputerUseDaemon"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/EYHN/PermissionFlow.git",
            revision: "9b02967a8b47133204c2456c56a1bfb393d4bd95"
        ),
    ],
    targets: [
        .target(
            name: "CUShared",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .target(
            name: "CUForeground",
            dependencies: ["CUShared"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Match Swift 6 dependencies' ObjC async continuation ABI.
                // https://github.com/swiftlang/swift/issues/81846
                .unsafeFlags(["-Xfrontend", "-checked-async-objc-bridging=on"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-framework", "SkyLight",
                ]),
            ]
        ),
        .target(
            name: "CUBackground",
            dependencies: ["CUShared"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .executableTarget(
            name: "CommaComputerUseDaemon",
            dependencies: [
                "CUShared",
                "CUBackground",
                "CUForeground",
                .product(name: "PermissionFlow", package: "PermissionFlow"),
                .product(name: "SystemSettingsKit", package: "PermissionFlow"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Match Swift 6 dependencies' ObjC async continuation ABI.
                // https://github.com/swiftlang/swift/issues/81846
                .unsafeFlags(["-Xfrontend", "-checked-async-objc-bridging=on"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(
            name: "CUTests",
            dependencies: [
                "CUShared", "CUBackground", "CUForeground", "CommaComputerUseDaemon",
                .product(name: "PermissionFlow", package: "PermissionFlow"),
            ]
        ),
    ]
)
