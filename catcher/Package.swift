// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Catcher",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "TranscriptionEngine", targets: ["TranscriptionEngine"]),
        .library(name: "GrokEngine", targets: ["GrokEngine"]),
        .library(name: "Verifier", targets: ["Verifier"]),
        .library(name: "SessionStore", targets: ["SessionStore"]),
        .library(name: "Pipeline", targets: ["Pipeline"]),
    ],
    targets: [
        .target(name: "AudioCapture"),
        .target(
            name: "TranscriptionEngine",
            dependencies: ["AudioCapture"]
        ),
        .target(
            name: "GrokEngine",
            dependencies: ["TranscriptionEngine", "AudioCapture"]
        ),
        .target(
            name: "Verifier",
            dependencies: ["AudioCapture", "TranscriptionEngine"]
        ),
        .target(name: "SessionStore"),
        .target(
            name: "Pipeline",
            dependencies: [
                "AudioCapture",
                "TranscriptionEngine",
                "Verifier",
                "SessionStore",
            ]
        ),
        .testTarget(
            name: "AudioCaptureTests",
            dependencies: ["AudioCapture"]
        ),
        .testTarget(
            name: "TranscriptionEngineTests",
            dependencies: ["TranscriptionEngine"]
        ),
        .testTarget(
            name: "GrokEngineTests",
            dependencies: ["GrokEngine"]
        ),
        .testTarget(
            name: "VerifierTests",
            dependencies: ["Verifier"]
        ),
        .testTarget(
            name: "SessionStoreTests",
            dependencies: ["SessionStore"]
        ),
        .testTarget(
            name: "PipelineTests",
            dependencies: ["Pipeline", "TranscriptionEngine", "AudioCapture", "SessionStore"]
        ),
    ]
)
