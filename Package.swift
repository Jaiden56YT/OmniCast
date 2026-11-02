// swift-tools-version:5.10
import PackageDescription

// libobs comes from the installed OBS.app (32.0.4); its headers are vendored by
// scripts/bootstrap.sh. scripts/bundle.sh wraps the build into OmniCast.app.
let obsFrameworks = "/Applications/OBS.app/Contents/Frameworks"

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
                .linkedFramework("CoreGraphics"),
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
