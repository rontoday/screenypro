// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenyPro",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ScreenyCore"),
        .target(name: "ScreenyCapture", dependencies: ["ScreenyCore"]),
        .target(name: "ScreenyRender", dependencies: ["ScreenyCore"]),
        .target(name: "ScreenyUI", dependencies: ["ScreenyCore"]),
        .executableTarget(
            name: "ScreenyPro",
            dependencies: ["ScreenyCore", "ScreenyCapture", "ScreenyRender", "ScreenyUI"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
