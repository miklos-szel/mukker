// swift-tools-version: 5.9
import PackageDescription

// Vendored Swift wrapper of transcribe.cpp (https://github.com/handy-computer/transcribe.cpp,
// MIT) — the on-device speech-to-text engine behind Dictation. `Sources/TranscribeCpp` is copied
// verbatim from the upstream tag below (`bindings/swift/Sources/TranscribeCpp`); the native code is
// the release's prebuilt xcframework, fetched by SwiftPM and verified against `checksum`.
//
// To upgrade: bump the tag in `url`, replace the checksum with
// `swift package compute-checksum TranscribeCpp.xcframework.zip` (= its SHA-256), and re-copy the
// wrapper sources from the same tag. The wrapper refuses to load a mismatched native ABI
// (`ABIHash.swift`), so the two halves must always come from the same tag.
let package = Package(
    name: "TranscribeCpp",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TranscribeCpp", targets: ["TranscribeCpp"]),
    ],
    targets: [
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.4.2/TranscribeCpp.xcframework.zip",
            checksum: "650a42ee7836558d3047f328078be2b8a8d4c6e9f6a0a3f4ea145481ad1c1a86"
        ),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ]
)
