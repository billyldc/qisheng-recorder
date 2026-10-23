// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QishengRecorder",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "QishengRecorder", targets: ["QishengRecorder"])],
    targets: [
        .target(name: "ReplayCore"),
        .executableTarget(name: "QishengRecorder", dependencies: ["ReplayCore"]),
        .executableTarget(name: "ReplayCoreChecks", dependencies: ["ReplayCore"], path: "Tests/ReplayCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
