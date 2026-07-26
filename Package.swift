// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DynamicWallpaper",
    defaultLocalization: "zh-Hant",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DynamicWallpaper", targets: ["DynamicWallpaper"])
    ],
    targets: [
        .executableTarget(
            name: "DynamicWallpaper",
            path: "Sources/DynamicWallpaper"
        )
    ],
    swiftLanguageModes: [.v5]
)
