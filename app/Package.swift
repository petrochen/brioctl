// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "brioctl-app",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "brioctl-app", targets: ["brioctl-app"]),
    ],
    targets: [
        // Everything testable: JSON model, CLI runner, store, LaunchAgents, hotkeys, URL scheme and the SwiftUI views.
        .target(name: "BrioctlCore"),
        // Only the @main entry point and the application delegate.
        .executableTarget(name: "brioctl-app", dependencies: ["BrioctlCore"]),
        .testTarget(
            name: "BrioctlCoreTests",
            dependencies: ["BrioctlCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
