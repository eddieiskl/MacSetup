// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacSetup",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The official MCP Swift SDK — backs MacSetupMCP. Depended on rather
        // than hand-rolled so the JSON-RPC/stdio protocol framing is exactly
        // what real MCP clients expect, not a reimplementation of it.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
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
        ),
        .executableTarget(
            name: "MacSetupMCP",
            dependencies: [
                "MacSetupCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/MacSetupMCP"
        )
    ]
)
