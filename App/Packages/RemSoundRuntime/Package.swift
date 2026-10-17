// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "RemSoundRuntime", platforms: [.macOS(.v14)], products: [
    .library(name: "RemSoundRuntime", targets: ["RemSoundRuntime"])
], targets: [
    .target(name: "RemSoundRuntime"),
    .testTarget(name: "RemSoundRuntimeTests", dependencies: ["RemSoundRuntime"])
])
