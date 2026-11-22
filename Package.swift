// swift-tools-version: 6.3

import PackageDescription

// one target per component, see md/DESIGN.md section 6b for the build order
let package = Package(
    name: "Tattle",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "tattle", targets: ["TattleCLI"])
    ],
    targets: [
        .target(name: "PCAPNG"),
        // no dependencies, Foundation only; ships its datasets in Resources
        .target(name: "Companies", resources: [.copy("Resources")]),
        // no dependencies, Foundation only; parses the App Privacy Report export and touches no storage
        .target(name: "PrivacyReport"),
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
            dependencies: ["PCAPNG", "PacketDecoder", "Flows", "Domains", "Storage", "Attribution", "PrivacyReport"]
        ),
        // read-time labels for the screens and the command line; never imported by the packet path
        .target(name: "Summary", dependencies: ["Companies", "Flows", "Domains", "Attribution"]),
        .target(name: "Capture", dependencies: ["PCAPNG", "Storage", "Pipeline"]),
        .executableTarget(name: "TattleCLI", dependencies: ["PCAPNG", "Storage", "Pipeline", "Capture", "Report", "Companies", "Summary"]),
        .executableTarget(
            name: "TattleApp",
            dependencies: ["PCAPNG", "PacketDecoder", "Flows", "Domains", "Storage", "Attribution", "Pipeline", "Capture", "Report", "Companies", "Summary", "PrivacyReport"]
        ),

        // shared test helpers: fixture lookup and byte builders
        .target(name: "TestSupport", dependencies: ["PCAPNG", "PacketDecoder", "Flows", "Domains"], path: "Tests/TestSupport"),

        .testTarget(name: "TattleCLITests", dependencies: ["PCAPNG", "TestSupport"]),
        .testTarget(name: "CompaniesTests", dependencies: ["Companies"]),
        .testTarget(name: "PrivacyReportTests", dependencies: ["PrivacyReport", "TestSupport"]),
        .testTarget(name: "SummaryTests", dependencies: ["Summary", "Companies", "Attribution", "Flows", "Domains", "PacketDecoder", "TestSupport"]),
        .testTarget(name: "PacketDecoderTests", dependencies: ["PacketDecoder", "TestSupport"]),
        .testTarget(name: "FlowsTests", dependencies: ["Flows", "TestSupport"]),
        .testTarget(name: "DomainsTests", dependencies: ["Domains", "TestSupport"]),
        .testTarget(name: "StorageTests", dependencies: ["Storage", "TestSupport"]),
        .testTarget(name: "AttributionTests", dependencies: ["Attribution", "TestSupport"]),
        .testTarget(name: "ReportTests", dependencies: ["Report", "Attribution", "Pipeline", "PCAPNG", "Companies", "Summary", "TestSupport"]),
        .testTarget(name: "PipelineTests", dependencies: ["Pipeline", "Storage", "PrivacyReport", "TestSupport"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "TestSupport"]),
        .testTarget(name: "TattleAppTests", dependencies: ["TattleApp", "Companies", "Summary", "Storage", "Pipeline", "PrivacyReport", "TestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
