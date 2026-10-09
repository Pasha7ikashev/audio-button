// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioButton",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "AudioButton", targets: ["AudioButton"])],
    targets: [
        .executableTarget(name: "AudioButton")
    ],
    swiftLanguageModes: [.v5]
)
