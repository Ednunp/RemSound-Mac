import Foundation
import RemSoundJam

extension ProductTestPack {
    static let audioConfigurations = "Every audio-axis test covers all THREE configurations (or says why not)"
    // Actual native branches: fallback primary ring, one card, and the repeated multi-card path.
    // These are owned software outputs, not Windows backend names or device acceptance.
    static let nativeOutputCounts = [0, 1, 2, 3]
    static let nativeCardModes = [false, true]

    static func checkNativeOutputFanout() -> (assertions: Int, failures: [String]) {
        var count = 0, failures = [String]()
        func require(_ condition: Bool, _ code: String) { count += 1; if !condition { failures.append("audio-axis.native." + code) } }
        require(nativeOutputCounts == [0, 1, 2, 3], "actual-output-count-boundaries")
        require(nativeCardModes == [false, true], "actual-card-mode-boundaries")
        require(ClockKeeping.on, "clock-branch-must-be-enabled")
        let samples = Array(repeating: [Float(0.25), Float(-0.125)], count: 128).flatMap { $0 }
        for outputCount in nativeOutputCounts {
            for cards in nativeCardModes {
                let fanout = PlaybackFanout(primary: StereoRing(capacity: OutputClock.maximumQueueFrames))
                let outputs = (0..<outputCount).map { _ in fanout.addOutput() }
                fanout.forCards = cards
                fanout.cardFrames = Array(repeating: 32, count: outputCount)
                fanout.write(samples)
                let targets = outputs.isEmpty ? [fanout.primary] : outputs
                require(fanout.rings.count == outputCount, "selected-output-count")
                require(Set(targets.map(ObjectIdentifier.init)).count == targets.count, "independent-output-rings")
                var heard = [[Float]]()
                for ring in targets {
                    require(ring.available > 0 && ring.available <= OutputClock.maximumQueueFrames, "bounded-output-depth")
                    let block = ring.read(ring.available)
                    heard.append(block)
                    require(block.count >= samples.count - 2 && block.allSatisfy(\.isFinite), "finite-output-frames")
                    require(block.suffix(2) == samples.suffix(2), "known-stereo-at-output")
                    require(ring.available == 0, "independent-consumption")
                }
                require(heard.dropFirst().allSatisfy { $0 == heard.first }, "same-mix-every-output")
                require(fanout.clocks.count == (cards && ClockKeeping.on ? targets.count : 0), "per-card-clock-branch")
                fanout.clear()
                require(fanout.rings.isEmpty && fanout.clocks.isEmpty && fanout.primary.available == 0 && !fanout.forCards, "full-fanout-retirement")
            }
        }
        return (count, failures)
    }

    static func checkAudioConfigurations(native: (() -> (assertions: Int, failures: [String])?)?) -> Step {
        guard let receipt = native?() else {
            return .init(name: audioConfigurations, status: "UNVERIFIED", assertions: 0, failures: ["actual-isolated-native-audio-axis-source-required"])
        }
        let punctuation = Set(".-".utf8)
        guard (1...8192).contains(receipt.assertions), receipt.failures.count <= 256,
            receipt.failures.allSatisfy({ $0.hasPrefix("audio-axis.native.") && $0.utf8.count <= 200 &&
                $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || punctuation.contains($0) } }) else {
            return .init(name: audioConfigurations, status: "FAIL", assertions: 0, failures: ["audio-axis.native.invalid-receipt"])
        }
        guard receipt.failures.allSatisfy({ $0.hasPrefix("audio-axis.native.unverified-") }) else {
            return .init(name: audioConfigurations, status: "FAIL", assertions: receipt.assertions, failures: receipt.failures)
        }
        let actual = checkNativeOutputFanout()
        let failures = receipt.failures + actual.failures
        let pending = failures.allSatisfy { $0.hasPrefix("audio-axis.native.unverified-") }
        return .init(name: audioConfigurations, status: failures.isEmpty ? "PASS" : pending ? "UNVERIFIED" : "FAIL", assertions: receipt.assertions + actual.assertions, failures: failures)
    }
}
