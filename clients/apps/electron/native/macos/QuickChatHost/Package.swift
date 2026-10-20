// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QuickChatHost",
    platforms: [
        // SpeechAnalyzer, the on-device streaming transcriber, starts in macOS 26.
        .macOS(.v26),
    ],
    products: [
        .executable(name: "QuickChatHost", targets: ["QuickChatHost"]),
    ],
    targets: [
        // Rules without AppKit state: the ⌘ hold and tap, the transcript text
        // and its product names, the text fit, the pending sends and Main's wire.
        .target(name: "QuickChatCore"),
        // Core Animation's mesh transform takes C structs, which Swift cannot pass.
        .target(name: "QuickChatPrivate"),
        .executableTarget(
            name: "QuickChatHost",
            dependencies: ["QuickChatCore", "QuickChatPrivate"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                // A bare executable has no bundle; embed Info.plist so macOS
                // finds NSMicrophoneUsageDescription and can show the TCC prompt.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "QuickChatCoreTests",
            dependencies: ["QuickChatCore"]
        ),
        .testTarget(
            name: "QuickChatHostTests",
            dependencies: ["QuickChatHost"]
        ),
    ]
)
