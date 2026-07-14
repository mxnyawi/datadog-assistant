// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DatadogAssistant",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DatadogAssistant", targets: ["DatadogAssistant"]),
    ],
    targets: [
        .executableTarget(
            name: "DatadogAssistant",
            path: "Sources/DatadogAssistant"
        ),
    ]
)
