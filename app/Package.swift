// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PrivacyFlow",
    platforms: [.macOS(.v14)],
    targets: [
        // The microphone's real-time callback. Written in C because Swift makes
        // no promise that a closure will not retain, release or allocate on the
        // audio thread.
        .target(name: "CaptureBuffer"),
        // Everything with an invariant worth testing, kept free of AppKit.
        .target(name: "PrivacyFlowCore"),
        .executableTarget(
            name: "PrivacyFlow",
            dependencies: ["PrivacyFlowCore", "CaptureBuffer"]
        ),
        .testTarget(
            name: "PrivacyFlowCoreTests",
            dependencies: ["PrivacyFlowCore", "CaptureBuffer"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
