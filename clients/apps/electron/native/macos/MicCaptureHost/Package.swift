// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MicCaptureHost",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MicCaptureHost", targets: ["MicCaptureHost"]),
    ],
    targets: [
        .executableTarget(
            name: "MicCaptureHost",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
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
    ]
)
