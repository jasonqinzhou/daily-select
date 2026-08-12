// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "daily-select",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "daily-select", targets: ["DailySelect"]),
        .library(name: "DailySelectCore", targets: ["DailySelectCore"]),
    ],
    targets: [
        .target(name: "DailySelectCore"),
        .executableTarget(name: "DailySelect", dependencies: ["DailySelectCore"]),
        .testTarget(name: "DailySelectCoreTests", dependencies: ["DailySelectCore"]),
    ]
)
