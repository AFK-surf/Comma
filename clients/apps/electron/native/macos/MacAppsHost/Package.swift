// swift-tools-version: 6.2

import PackageDescription

// EventKit, Contacts and MapKit hand back ObjC objects that are not Sendable;
// the targets stay in Swift 5 mode, and the flag matches the Swift 6 MCP
// package's ObjC async continuation ABI (https://github.com/swiftlang/swift/issues/81846).
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(["-Xfrontend", "-checked-async-objc-bridging=on"]),
]

let package = Package(
    name: "MacAppsHost",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MacAppsHost", targets: ["MacAppsHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(
            name: "MacApps",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Contacts"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreImage"),
                .linkedFramework("EventKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("MapKit"),
                .linkedFramework("Network"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "MacAppsHost",
            dependencies: [
                "MacApps",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: [
                // A bare executable has no bundle; embed Info.plist so the
                // frameworks find their usage descriptions.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "MacAppsTests",
            dependencies: [
                "MacApps",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
