// swift-tools-version:5.10
import Foundation
import PackageDescription

// libobs 32.0.4 and its headers are vendored by scripts/bootstrap.sh: the
// binaries are copied out of OBS.app once into vendor/obs-runtime, and
// scripts/bundle.sh copies them into OmniCast.app, so OBS.app isn't needed after that.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let obsFrameworks = "\(root)/vendor/obs-runtime/Frameworks"

let package = Package(
    name: "OmniCast",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "OmniEngine",
            path: "Sources/OmniEngine",
            cSettings: [
                .headerSearchPath("../../vendor/obs-studio/libobs"),
                .headerSearchPath("../../vendor/include"),
                .unsafeFlags(["-fobjc-arc", "-Wno-unused-parameter"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-F\(obsFrameworks)", "-framework", "libobs"]),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreAudioKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "OmniCast",
            dependencies: ["OmniEngine"],
            path: "Sources/OmniCast",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
