// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentDeck", targets: ["AgentDeck"]),
        .executable(name: "agentdeckctl", targets: ["AgentDeckCLI"])
    ],
    targets: [
        .target(name: "AgentDeckCore"),
        .executableTarget(name: "AgentDeck", dependencies: ["AgentDeckCore"]),
        .executableTarget(name: "AgentDeckCLI", dependencies: ["AgentDeckCore"]),
        .testTarget(name: "AgentDeckCoreTests", dependencies: ["AgentDeckCore"])
    ],
    swiftLanguageModes: [.v5]
)
