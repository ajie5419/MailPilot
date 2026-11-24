// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailPilot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MailPilotCore",
            targets: ["MailPilotCore"]
        ),
        .executable(
            name: "MailPilot",
            targets: ["MailPilotApp"]
        )
    ],
    targets: [
        .target(
            name: "MailPilotCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "MailPilotApp",
            dependencies: ["MailPilotCore"]
        ),
        .testTarget(
            name: "MailPilotCoreTests",
            dependencies: ["MailPilotCore"]
        )
    ]
)
