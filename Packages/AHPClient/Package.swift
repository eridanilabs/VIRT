// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AHPClient",
    // macOS lets `swift test` run the client's tests on the build machine, without a simulator.
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [
        .library(name: "AHPClient", targets: ["AHPClient"]),
    ],
    targets: [
        .target(name: "AHPClient"),
        .testTarget(name: "AHPClientTests", dependencies: ["AHPClient"]),
    ]
)
