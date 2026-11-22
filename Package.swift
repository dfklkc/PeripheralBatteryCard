// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PeripheralBatteryCard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PeripheralBatteryCore",
            targets: ["PeripheralBatteryCore"]
        ),
        .executable(
            name: "PeripheralBatteryCard",
            targets: ["PeripheralBatteryCard"]
        )
    ],
    targets: [
        .target(
            name: "PeripheralBatteryCore",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "PeripheralBatteryCard",
            dependencies: ["PeripheralBatteryCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "PeripheralBatteryCoreTests",
            dependencies: ["PeripheralBatteryCore"]
        )
    ]
)
