// swift-tools-version: 6.3

import PackageDescription

// one target per component, see md/DESIGN.md section 6b for the build order
let package = Package(
    name: "WatchCapture",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(name: "PCAPNG"),
        .target(name: "PacketDecoder", dependencies: ["PCAPNG"]),
        .target(name: "Flows", dependencies: ["PacketDecoder"]),
        .target(name: "Domains", dependencies: ["PacketDecoder", "Flows"]),
        .target(
            name: "Storage",
            dependencies: ["Flows", "Domains", "PacketDecoder"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "Attribution", dependencies: ["Flows", "Domains"]),
        .target(name: "Report", dependencies: ["Flows", "Domains", "Attribution", "Storage", "PacketDecoder"]),
        .target(
            name: "Pipeline",
            dependencies: ["PCAPNG", "PacketDecoder", "Flows", "Domains", "Storage", "Attribution"]
        ),
        .target(name: "Capture", dependencies: ["PCAPNG", "Pipeline"]),
        .executableTarget(name: "WatchCapture", dependencies: ["PCAPNG", "Pipeline", "Capture", "Report"]),
        .executableTarget(
            name: "WatchApp",
            dependencies: ["PCAPNG", "PacketDecoder", "Flows", "Domains", "Storage", "Attribution", "Pipeline", "Capture", "Report"]
        ),

        // shared test helpers: fixture lookup and byte builders
        .target(name: "TestSupport", dependencies: ["PCAPNG", "PacketDecoder", "Flows", "Domains"], path: "Tests/TestSupport"),

        .testTarget(name: "WatchCaptureTests", dependencies: ["PCAPNG", "TestSupport"]),
        .testTarget(name: "PacketDecoderTests", dependencies: ["PacketDecoder", "TestSupport"]),
        .testTarget(name: "FlowsTests", dependencies: ["Flows", "TestSupport"]),
        .testTarget(name: "DomainsTests", dependencies: ["Domains", "TestSupport"]),
        .testTarget(name: "StorageTests", dependencies: ["Storage", "TestSupport"]),
        .testTarget(name: "AttributionTests", dependencies: ["Attribution", "TestSupport"]),
        .testTarget(name: "ReportTests", dependencies: ["Report", "Attribution", "Pipeline", "PCAPNG", "TestSupport"]),
        .testTarget(name: "PipelineTests", dependencies: ["Pipeline", "TestSupport"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "TestSupport"]),
        .testTarget(name: "WatchAppTests", dependencies: ["WatchApp", "TestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
