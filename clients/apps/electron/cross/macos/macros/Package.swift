// swift-tools-version: 6.0

import PackageDescription

let pluginDependencies: [Target.Dependency] = [
    .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
    .product(name: "SwiftSyntax", package: "swift-syntax"),
    .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
    .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
]

let package = Package(
    name: "MacOSCrossMacros",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SwiftUIMacros", targets: ["SwiftUIMacros"]),
        .executable(name: "PreviewsMacros", targets: ["PreviewsMacros"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        .executableTarget(name: "SwiftUIMacros", dependencies: pluginDependencies),
        .executableTarget(name: "PreviewsMacros", dependencies: pluginDependencies),
    ]
)
