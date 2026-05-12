// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "secvf-cli",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Existing CLI executable
        .executableTarget(
            name: "secvf-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/secvf-cli"
        ),
        // New: MCP server core (pure logic, testable, no I/O at boundaries)
        .target(
            name: "SecVFMCPCore",
            dependencies: [],
            path: "Sources/SecVFMCPCore"
        ),
        // New: MCP server executable (thin entry point that wires Core to stdio + filesystem)
        .executableTarget(
            name: "secvf-mcp",
            dependencies: [
                "SecVFMCPCore",
            ],
            path: "Sources/secvf-mcp"
        ),
        // Test target: pure Core logic, mocked dependencies, fast feedback loop
        .testTarget(
            name: "SecVFMCPCoreTests",
            dependencies: ["SecVFMCPCore"],
            path: "Tests/SecVFMCPCoreTests"
        ),
    ]
)
