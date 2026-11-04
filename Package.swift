// swift-tools-version: 6.2
import PackageDescription

// `swift build` builds the code; `./scripts/build.sh` builds the code and wraps it in Encore.app.
let package = Package(
    name: "Encore",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Encore", targets: ["Encore"]),
    ],
    targets: [
        // Bluetooth transport + OPPO/HeyMelody wire protocol. No UI.
        .target(
            name: "EncoKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
        // The menu bar app.
        .executableTarget(
            name: "Encore",
            dependencies: ["EncoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        // Pure-logic checks for the packet codec (runs without Bluetooth).
        .executableTarget(
            name: "EncoKitSelfTest",
            dependencies: ["EncoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
