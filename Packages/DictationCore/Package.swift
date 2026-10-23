// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DictationCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DictationCore", targets: ["DictationCore"])],
    dependencies: [
        .package(url: "https://github.com/altic-dev/FluidAudio.git", revision: "eb1e6628998e47022799d305b52c2680d3576801")
    ],
    targets: [
        .target(name: "DictationCore", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], resources: [.process("Resources")])
    ]
)
