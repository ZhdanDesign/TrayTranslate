// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrayTranslate",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TranslateCore"),
        .executableTarget(name: "TrayTranslate", dependencies: ["TranslateCore"]),
        .executableTarget(name: "SelfTest", dependencies: ["TranslateCore"]),
    ],
    swiftLanguageModes: [.v5]
)
