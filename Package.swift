// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WiFiDoctor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WiFiDoctor",
            path: "WiFiDoctor",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)