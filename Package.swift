// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ExplorerCore", targets: ["ExplorerCore"]),
        .library(name: "ExplorerBrowsing", targets: ["ExplorerBrowsing"]),
        .library(name: "ExplorerOperations", targets: ["ExplorerOperations"]),
        .library(name: "ExplorerUI", targets: ["ExplorerUI"]),
        .executable(name: "ExplorerApp", targets: ["ExplorerApp"]),
    ],
    targets: [
        .target(name: "ExplorerCore"),
        .target(
            name: "ExplorerBrowsing",
            dependencies: ["ExplorerCore"]
        ),
        .target(name: "ExplorerOperations"),
        .target(name: "ExplorerUI"),
        .executableTarget(
            name: "ExplorerApp",
            dependencies: ["ExplorerCore", "ExplorerBrowsing", "ExplorerOperations", "ExplorerUI"]
        ),
        .testTarget(
            name: "ExplorerCoreTests",
            dependencies: ["ExplorerCore"]
        ),
        .testTarget(
            name: "ExplorerBrowsingTests",
            dependencies: ["ExplorerCore", "ExplorerBrowsing"]
        ),
        .testTarget(
            name: "ExplorerOperationsTests",
            dependencies: ["ExplorerOperations"]
        ),
        .testTarget(
            name: "ExplorerUITests",
            dependencies: ["ExplorerUI"]
        ),
    ]
)
