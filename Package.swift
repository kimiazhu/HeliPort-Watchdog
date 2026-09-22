// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "heliport-watchdog",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "heliport-watchdog", targets: ["HeliPortWatchdog"])
    ],
    targets: [
        .executableTarget(
            name: "HeliPortWatchdog",
            path: "Sources/HeliPortWatchdog"
        )
    ]
)
