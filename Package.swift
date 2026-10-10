// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StickyClip",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "StickyClip", targets: ["StickyClip"])
    ],
    targets: [
        .executableTarget(
            name: "StickyClip",
            path: "Sources/StickyClip",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
