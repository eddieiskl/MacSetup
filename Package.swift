// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacSetup",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WebAppHost",
            path: "Sources/WebAppHost"
        ),
        .target(
            name: "MacSetupCore",
            path: "Sources/MacSetupCore"
        ),
        .executableTarget(
            name: "MacSetup",
            dependencies: ["MacSetupCore"],
            path: "Sources/MacSetup",
            resources: [.copy("Resources/catalog.json"), .copy("Resources/about.json")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
