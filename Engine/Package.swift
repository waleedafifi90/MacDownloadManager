// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DownloadEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DownloadEngine", targets: ["DownloadEngine"]),
        .library(name: "DownloadEngineTestSupport", targets: ["DownloadEngineTestSupport"]),
        .executable(name: "mdm", targets: ["mdm"]),
    ],
    targets: [
        .target(name: "DownloadEngine"),
        .target(name: "DownloadEngineTestSupport"),
        .executableTarget(name: "mdm", dependencies: ["DownloadEngine"]),
        .testTarget(name: "DownloadEngineTests", dependencies: ["DownloadEngine", "DownloadEngineTestSupport"]),
    ]
)
