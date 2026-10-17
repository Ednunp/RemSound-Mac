// swift-tools-version: 5.9
import PackageDescription
import Foundation
let opus = ProcessInfo.processInfo.environment["REMSOUND_OPUS_LIBRARY"] ?? "/opt/homebrew/lib/libopus.a"
let lame = ProcessInfo.processInfo.environment["REMSOUND_LAME_LIBRARY"] ?? "/opt/homebrew/lib/libmp3lame.dylib"
let flac = ProcessInfo.processInfo.environment["REMSOUND_FLAC_LIBRARY"] ?? "/opt/homebrew/lib/libFLAC.a"
let package = Package(name: "RemSoundMac", platforms: [.macOS(.v14)], products: [
    .executable(name: "RemSound", targets: ["RemSoundApp"]),
    .executable(name: "RemSoundUpdater", targets: ["RemSoundUpdater"])
], dependencies: [
    // Playing together through a server: plain Swift, so it is also built and tested on Windows against the real relay.
    .package(path: "Packages/RemSoundJam"),
    .package(path: "Packages/RemSoundRuntime"),
], targets: [
    .target(name: "UpdateSupport", cSettings: [.headerSearchPath("vendor")],
        linkerSettings: [.linkedLibrary("archive")]),
    .target(name: "AudioSupport", linkerSettings: [.unsafeFlags([opus, lame, flac, "-Xlinker", "-rpath",
        "-Xlinker", "@executable_path/../Frameworks"])]),
    .target(name: "RemSoundCore", dependencies: ["AudioSupport", "UpdateSupport", .product(name: "RemSoundJam", package: "RemSoundJam"), .product(name: "RemSoundSim", package: "RemSoundJam"),
        .product(name: "RemSoundRuntime", package: "RemSoundRuntime")], resources: [.copy("Resources/web-listener.html")]),
    .executableTarget(name: "RemSoundApp", dependencies: ["RemSoundCore", "AudioSupport",
        .product(name: "RemSoundJam", package: "RemSoundJam"), .product(name: "RemSoundSim", package: "RemSoundJam"),
        .product(name: "RemSoundRuntime", package: "RemSoundRuntime")]),
    .executableTarget(name: "RemSoundUpdater", dependencies: ["RemSoundCore"]),
    .testTarget(name: "RemSoundCoreTests", dependencies: ["RemSoundCore", "AudioSupport",
        .product(name: "RemSoundJam", package: "RemSoundJam")], resources: [.copy("Fixtures")]),
    .testTarget(name: "RemSoundAppTests", dependencies: ["RemSoundApp",
        .product(name: "RemSoundRuntime", package: "RemSoundRuntime")])
])
