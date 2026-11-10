// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MovieFXPlayer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MovieFXPlayer", targets: ["MovieFXPlayer"])
    ],
    targets: [
        .executableTarget(
            name: "MovieFXPlayer",
            resources: [.copy("Resources/AppIcon.icns")]
        ),
        .testTarget(
            name: "MovieFXPlayerTests",
            dependencies: [.target(name: "MovieFXPlayer")],
            resources: [.process("Resources")]
        )
    ]
)
