// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDownloadManager",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../Engine")],
    targets: [
        // Messages and socket plumbing shared by the app and the browser host.
        .target(name: "CaptureProtocol"),
        // Download list state, independent of the UI so it can be tested.
        .target(name: "DownloadsCore", dependencies: [
            "CaptureProtocol", .product(name: "DownloadEngine", package: "Engine"),
        ]),
        .executableTarget(name: "MacDownloadManager", dependencies: ["DownloadsCore"]),
        // Signs release DMGs so the app's updater accepts them (key in the Keychain).
        .executableTarget(name: "mdm-release", dependencies: ["DownloadsCore"]),
        // Started by Chrome for the extension (Native Messaging).
        .executableTarget(name: "mdm-native-host", dependencies: ["CaptureProtocol"]),
        .testTarget(
            name: "DownloadsCoreTests",
            dependencies: [
                "DownloadsCore", "CaptureProtocol", "mdm-native-host",
                .product(name: "DownloadEngineTestSupport", package: "Engine"),
            ]
        ),
    ]
)
