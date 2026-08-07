// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NRadioRecorder",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NRadioRecorder", targets: ["NRadioRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "NRadioRecorder",
            path: "Sources/NRadioRecorder"
        )
    ]
)
