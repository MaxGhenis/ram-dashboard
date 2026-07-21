// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Rambar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RambarKit", targets: ["RambarKit"]),
        .library(name: "RambarSystem", targets: ["RambarSystem"]),
        .executable(name: "rambar", targets: ["rambar"]),
        .executable(name: "RambarFace", targets: ["RambarFace"]),
    ],
    targets: [
        .target(name: "RambarKit"),
        .target(name: "RambarSystem", dependencies: ["RambarKit"]),
        .executableTarget(name: "rambar", dependencies: ["RambarKit", "RambarSystem"]),
        .executableTarget(name: "RambarFace", dependencies: ["RambarKit", "RambarSystem"]),
        .testTarget(name: "RambarKitTests", dependencies: ["RambarKit"]),
        .testTarget(name: "RambarSystemTests", dependencies: ["RambarSystem", "RambarKit"]),
    ]
)
