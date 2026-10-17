// swift-tools-version: 5.9
import PackageDescription

// RemSoundJam: playing together through a RemSound server - the server connection (relay groups), the server's
// metronome, capture timing and click placement - and the rest of the Mac app's logic that needs no Mac: the receive
// buffer and its clock keeping, the EQ, remote volume, the Ogg writer, the network recorder. Plain Swift and Foundation
// only, so it builds and its tests run on a Mac and on Windows alike (Ed's machine checks it against the Windows RemSound
// and the real relay). The Mac app joins it to Core Audio, the network socket and AppKit in RemSoundCore and RemSoundApp.
//
// RemSoundSim: the Mac simulator - the app's own receive path (RemSoundJam's) with fake sound cards and a fake network,
// in simulated time - and its listening. Runs only for explicit offline replay/product commands; normal app startup never invokes it.
let package = Package(
    name: "RemSoundJam",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RemSoundJam", targets: ["RemSoundJam"]),
        .library(name: "RemSoundSim", targets: ["RemSoundSim"])],
    targets: [
        .target(name: "RemSoundJam"),
        .target(name: "RemSoundSim", dependencies: ["RemSoundJam"]),
        .testTarget(name: "RemSoundJamTests", dependencies: ["RemSoundJam"]),
        .testTarget(name: "RemSoundSimTests", dependencies: ["RemSoundSim", "RemSoundJam"], exclude: ["Recordings"]),
    ]
)
