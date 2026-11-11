// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VIRTKit",
    // macOS lets `swift test` run VIRTKit's tests on the build machine, without a simulator.
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [
        .library(name: "VIRTKit", targets: ["VIRTKit"]),
    ],
    dependencies: [
        // The official Agent Host Protocol Swift client. Pinned exactly; bump it in its own PR.
        .package(url: "https://github.com/microsoft/agent-host-protocol.git", exact: "1.0.0"),
    ],
    targets: [
        .target(
            name: "VIRTKit",
            dependencies: [
                .product(name: "AgentHostProtocol", package: "agent-host-protocol"),
                .product(name: "AgentHostProtocolClient", package: "agent-host-protocol"),
            ]
        ),
        .testTarget(
            name: "VIRTKitTests",
            dependencies: [
                "VIRTKit",
                // For `InMemoryTransport`, which plays the host in the tests.
                .product(name: "AgentHostProtocolClient", package: "agent-host-protocol"),
            ]
        ),
    ]
)
