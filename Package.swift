// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Roomsmith",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Roomsmith", targets: ["Roomsmith"]),
        .executable(name: "roomsmith-mcp", targets: ["roomsmith-mcp"]),
        .library(name: "RoomsmithCore", targets: ["RoomsmithCore"]),
    ],
    targets: [
        // Document model, geometry, commands, persistence, import/export, agent tool API.
        // Foundation/CoreGraphics only: no AppKit, no RealityKit.
        .target(name: "RoomsmithCore"),
        // Local agent transport (Unix domain socket, newline-delimited JSON).
        .target(name: "RoomsmithIPC", dependencies: ["RoomsmithCore"]),
        // The macOS app (SwiftUI + AppKit + RealityKit).
        .executableTarget(name: "Roomsmith", dependencies: ["RoomsmithCore", "RoomsmithIPC"]),
        // MCP stdio server and CLI that talks to the running app.
        .executableTarget(name: "roomsmith-mcp", dependencies: ["RoomsmithCore", "RoomsmithIPC"]),
        .testTarget(name: "RoomsmithCoreTests", dependencies: ["RoomsmithCore", "RoomsmithIPC"]),
        // Drives the real AppKit views (plan, 3D) with synthesized events.
        .testTarget(name: "RoomsmithAppTests", dependencies: ["Roomsmith", "RoomsmithCore"]),
    ]
)
