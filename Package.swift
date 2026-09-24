// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "heliport-watchdog",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "heliport-watchdog", targets: ["HeliPortWatchdog"]),
        .executable(name: "HeliPortWatchdog", targets: ["HeliPortWatchdogApp"]),
        .library(name: "WatchdogCore", targets: ["WatchdogCore"])
    ],
    targets: [
        .target(
            name: "WatchdogCore",
            path: "Sources/WatchdogCore"
        ),
        .executableTarget(
            name: "HeliPortWatchdog",
            dependencies: ["WatchdogCore"],
            path: "Sources/HeliPortWatchdog"
        ),
        .executableTarget(
            name: "HeliPortWatchdogApp",
            dependencies: ["WatchdogCore"],
            path: "Sources/HeliPortWatchdogApp"
        ),
        .testTarget(
            name: "WatchdogCoreTests",
            dependencies: ["WatchdogCore"],
            path: "Tests/WatchdogCoreTests"
        )
    ]
)
