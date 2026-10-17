import XCTest
@testable import RemSoundJam

final class PushToTalkAudioGateTests: XCTestCase {
    private func settings(trigger: PushToTalkTrigger = .key,
                          path: PushToTalkCapturePath = .both) -> PushToTalkGateConfiguration {
        var result = PushToTalkGateConfiguration()
        result.enabled = true; result.trigger = trigger; result.capturePath = path
        return result
    }
    private func apply(_ gate: inout PushToTalkAudioGate, _ lane: inout PushToTalkLaneState,
                       _ input: [Float], end: Int64 = 1_000) -> [Float] {
        var output = [Float](repeating: -99, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                XCTAssertTrue(gate.apply(lane: &lane, input: source, output: destination, blockEndFrame: end))
            }
        }
        return output
    }
    private func close(_ gate: inout PushToTalkAudioGate, _ lane: inout PushToTalkLaneState) {
        _ = apply(&gate, &lane, [Float](repeating: 0, count: 2 * (PushToTalkAudioGate.fadeFrames + 1)))
        XCTAssertEqual(lane.gain, 0)
    }

    func testDefaultsDisableGateAndPreserveAllLanesAndRecording() {
        var gate = PushToTalkAudioGate()
        let config = gate.configuration
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.capturePath, .both)
        XCTAssertEqual(config.trigger, .key)
        XCTAssertEqual(config.levelDb, -40)
        XCTAssertFalse(config.bypassForPlugin); XCTAssertFalse(config.bypassForRecording)
        XCTAssertTrue(gate.recordsUngated); XCTAssertTrue(gate.isOpen(atFrame: 0))
        for kind in PushToTalkSendLane.allCases {
            var lane = PushToTalkLaneState(kind)
            XCTAssertFalse(gate.holds(kind))
            XCTAssertEqual(apply(&gate, &lane, [0.5, -0.5]), [0.5, -0.5])
        }
    }

    func testThresholdBoundsAndDefaultHaveIndependentLinearValues() {
        var config = PushToTalkGateConfiguration()
        XCTAssertEqual(config.levelLinear, 0.01, accuracy: 0.000001)
        for (db, expected): (Int, Float) in [(Int.min, 0.00031622777), (-70, 0.00031622777),
                                           (-20, 0.1), (-10, 0.31622777), (Int.max, 0.31622777)] {
            config.levelDb = db
            XCTAssertEqual(config.levelLinear, expected, accuracy: 0.0000001)
        }
    }

    func testPathHoldsOnlyChosenCaptureAndPluginByDefault() {
        var gate = PushToTalkAudioGate()
        for path in PushToTalkCapturePath.allCases {
            gate.configure(settings(path: path))
            XCTAssertEqual(gate.holds(.inputCapture), path != .systemAudio)
            XCTAssertEqual(gate.holds(.systemCapture), path != .input)
            XCTAssertTrue(gate.holds(.plugin))
        }
    }

    func testClosedKeyLaneFadesThenCarriesSameLengthSilence() {
        var gate = PushToTalkAudioGate(); gate.configure(settings())
        var lane = PushToTalkLaneState(.inputCapture)
        let input = [Float](repeating: 0.5, count: 2 * 481)
        let output = apply(&gate, &lane, input)
        XCTAssertEqual(output.count, input.count)
        XCTAssertEqual(output[0], 0.5 * (1 - Float(1) / 240), accuracy: 0.000001)
        XCTAssertLessThan(abs(output[2 * 239]), 0.000002)
        XCTAssertTrue(output[(2 * 240)...].allSatisfy { $0 == 0 })
        XCTAssertEqual(lane.gain, 0)
    }

    func testKeyOpeningStartsAtFirstFrameWithFiveMillisecondFade() {
        var gate = PushToTalkAudioGate(); gate.configure(settings())
        var lane = PushToTalkLaneState(.inputCapture); close(&gate, &lane)
        gate.setKeyTalking(true)
        let output = apply(&gate, &lane, [Float](repeating: 0.5, count: 2 * 241))
        XCTAssertEqual(output[0], 0.5 / 240, accuracy: 0.000001)
        XCTAssertEqual(output[2 * 119], 0.25, accuracy: 0.000002)
        XCTAssertEqual(output.last!, 0.5, accuracy: 0.000002)
        XCTAssertTrue(gate.isOpen(atFrame: 1_000))
    }

    func testFadeContinuesAcrossBlocksAndReversesSmoothly() {
        var gate = PushToTalkAudioGate(); gate.configure(settings())
        var lane = PushToTalkLaneState(.inputCapture); close(&gate, &lane)
        gate.setKeyTalking(true)
        _ = apply(&gate, &lane, [Float](repeating: 1, count: 2 * 120))
        XCTAssertEqual(lane.gain, 0.5, accuracy: 0.000002)
        gate.setKeyTalking(false)
        let output = apply(&gate, &lane, [Float](repeating: 1, count: 2 * 121))
        XCTAssertEqual(output[0], 0.5 - Float(1) / 240, accuracy: 0.000002)
        XCTAssertEqual(output.last!, 0, accuracy: 0.000002)
    }

    func testLaneFadesAreIndependentAndUnheldLanePasses() {
        var gate = PushToTalkAudioGate(); gate.configure(settings(path: .input))
        var input = PushToTalkLaneState(.inputCapture), system = PushToTalkLaneState(.systemCapture)
        var plugin = PushToTalkLaneState(.plugin)
        close(&gate, &input)
        XCTAssertEqual(plugin.gain, 1); XCTAssertEqual(system.gain, 1)
        XCTAssertEqual(apply(&gate, &system, [0.5, -0.5]), [0.5, -0.5])
        _ = apply(&gate, &plugin, [1, 1])
        XCTAssertGreaterThan(plugin.gain, 0); XCTAssertLessThan(plugin.gain, 1)
        XCTAssertEqual(input.gain, 0)
    }

    func testLevelOpeningIncludesFirstThresholdSampleAndBothPolarities() {
        for source: [Float] in [[0, 0, 0, -0.01, 0.005, 0.005],
                               [0, 0, 0.01, 0, 0.005, 0.005]] {
            var gate = PushToTalkAudioGate(); gate.configure(settings(trigger: .level))
            var lane = PushToTalkLaneState(.inputCapture); close(&gate, &lane)
            let output = apply(&gate, &lane, source, end: 3)
            XCTAssertEqual(Array(output.prefix(2)), [0, 0])
            XCTAssertGreaterThan(max(abs(output[2]), abs(output[3])), 0)
            XCTAssertGreaterThan(output[4], 0, "No extra block or lookahead delay")
            XCTAssertTrue(gate.isOpen(atFrame: 3))
        }
    }

    func testBelowThresholdDoesNotOpenLevelGate() {
        var gate = PushToTalkAudioGate(); gate.configure(settings(trigger: .level))
        var lane = PushToTalkLaneState(.inputCapture); close(&gate, &lane)
        XCTAssertEqual(apply(&gate, &lane, [0.00999, -0.00999], end: 1), [0, 0])
        XCTAssertFalse(gate.isOpen(atFrame: 1))
    }

    func testHangUsesLastLoudFrameEndAndInclusiveHalfSecond() {
        var gate = PushToTalkAudioGate(); gate.configure(settings(trigger: .level))
        var lane = PushToTalkLaneState(.inputCapture); close(&gate, &lane)
        _ = apply(&gate, &lane, [0.1, 0, 0, 0, 0.1, 0, 0, 0], end: 104)
        XCTAssertTrue(gate.isOpen(atFrame: 24_103))
        XCTAssertFalse(gate.isOpen(atFrame: 24_104))
    }

    func testLoudHistoryDoesNotMoveBackWithAnotherCaptureLane() {
        var gate = PushToTalkAudioGate(); gate.configure(settings(trigger: .level))
        var input = PushToTalkLaneState(.inputCapture), system = PushToTalkLaneState(.systemCapture)
        _ = apply(&gate, &input, [0.1, 0], end: 200)
        _ = apply(&gate, &system, [0.1, 0], end: 100)
        XCTAssertTrue(gate.isOpen(atFrame: 24_200))
        XCTAssertFalse(gate.isOpen(atFrame: 24_201))
    }

    func testUnheldCaptureCannotOpenOtherLane() {
        var gate = PushToTalkAudioGate(); gate.configure(settings(trigger: .level, path: .input))
        var system = PushToTalkLaneState(.systemCapture), input = PushToTalkLaneState(.inputCapture)
        XCTAssertEqual(apply(&gate, &system, [1, 1], end: 100), [1, 1])
        XCTAssertFalse(gate.isOpen(atFrame: 100))
        close(&gate, &input)
        XCTAssertEqual(apply(&gate, &input, [0.001, 0.001], end: 101), [0, 0])
    }

    func testPluginCannotTriggerButFollowsCaptureOpeningAndExpiry() {
        var gate = PushToTalkAudioGate(); gate.configure(settings(trigger: .level))
        var plugin = PushToTalkLaneState(.plugin), input = PushToTalkLaneState(.inputCapture)
        close(&gate, &plugin)
        XCTAssertEqual(apply(&gate, &plugin, [1, 1], end: 100), [0, 0])
        XCTAssertFalse(gate.isOpen(atFrame: 100))
        _ = apply(&gate, &input, [0.1, 0], end: 101)
        XCTAssertGreaterThan(apply(&gate, &plugin, [1, 1], end: 102)[0], 0)
        _ = apply(&gate, &plugin, [Float](repeating: 1, count: 2 * 241), end: 25_000)
        XCTAssertEqual(apply(&gate, &plugin, [1, 1], end: 25_001), [0, 0])
    }

    func testPluginBypassAndRecordingPolicyAreIndependent() {
        var gate = PushToTalkAudioGate(), config = settings()
        gate.configure(config)
        XCTAssertFalse(gate.recordsUngated); XCTAssertTrue(gate.holds(.plugin))
        config.bypassForRecording = true; gate.configure(config)
        XCTAssertTrue(gate.recordsUngated); XCTAssertTrue(gate.holds(.plugin))
        config.bypassForRecording = false; config.bypassForPlugin = true; gate.configure(config)
        XCTAssertFalse(gate.recordsUngated); XCTAssertFalse(gate.holds(.plugin))
        var plugin = PushToTalkLaneState(.plugin)
        XCTAssertEqual(apply(&gate, &plugin, [0.5, -0.5]), [0.5, -0.5])
        XCTAssertFalse(gate.isOpen(atFrame: 1_000))
    }

    func testConfigureRetiresKeyAndLevelHistoryButRestoresBypassGradually() {
        var gate = PushToTalkAudioGate(); gate.configure(settings())
        gate.setKeyTalking(true); gate.configure(settings())
        XCTAssertFalse(gate.isOpen(atFrame: 0))
        var lane = PushToTalkLaneState(.inputCapture)
        gate.configure(settings(trigger: .level))
        _ = apply(&gate, &lane, [0.1, 0.1], end: 100)
        gate.configure(settings(trigger: .level))
        XCTAssertFalse(gate.isOpen(atFrame: 100))
        close(&gate, &lane)
        gate.configure(PushToTalkGateConfiguration())
        let output = apply(&gate, &lane, [Float](repeating: 1, count: 2 * 241))
        XCTAssertGreaterThan(output[0], 0); XCTAssertLessThan(output[0], 0.01)
        XCTAssertEqual(output.last!, 1, accuracy: 0.000002)
        XCTAssertTrue(gate.recordsUngated)
    }

    func testNonfiniteAudioNeitherTriggersNorEscapesToOutput() {
        var gate = PushToTalkAudioGate(); gate.configure(settings(trigger: .level))
        var lane = PushToTalkLaneState(.inputCapture); close(&gate, &lane)
        XCTAssertEqual(apply(&gate, &lane, [.nan, .infinity, -.infinity, 0]), [0, 0, 0, 0])
        XCTAssertFalse(gate.isOpen(atFrame: 1_000))
        gate.configure(PushToTalkGateConfiguration())
        XCTAssertTrue(apply(&gate, &lane, [.nan, .infinity]).allSatisfy { $0 == 0 })
    }

    func testInvalidGeometryAndTimeLeaveStateAndDestinationUntouched() {
        var gate = PushToTalkAudioGate(); gate.configure(settings())
        var lane = PushToTalkLaneState(.inputCapture)
        for (source, size, end): ([Float], Int, Int64) in [([1], 1, 1), ([1, 1], 1, 1), ([1, 1], 2, .min)] {
            var output = [Float](repeating: -99, count: size)
            source.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { destination in
                    XCTAssertFalse(gate.apply(lane: &lane, input: input, output: destination, blockEndFrame: end))
                }
            }
            XCTAssertTrue(output.allSatisfy { $0 == -99 }); XCTAssertEqual(lane.gain, 1)
        }
        XCTAssertEqual(gate.takeTransitions().closes, 0)
    }

    func testEmptyBuffersAreNoOpAndOutputTailIsNotOverwritten() {
        var gate = PushToTalkAudioGate(), lane = PushToTalkLaneState(.inputCapture)
        XCTAssertEqual(apply(&gate, &lane, []), [])
        var output: [Float] = [-99, -99, 7, 8]
        [Float](arrayLiteral: 0.5, -0.5).withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                XCTAssertTrue(gate.apply(lane: &lane, input: source, output: destination, blockEndFrame: 1))
            }
        }
        XCTAssertEqual(output, [0.5, -0.5, 7, 8])
    }

    func testInPlaceLevelScanMatchesSeparateDestination() {
        var gate = PushToTalkAudioGate(); gate.configure(settings(trigger: .level))
        var lane = PushToTalkLaneState(.inputCapture); close(&gate, &lane)
        var copy = gate, copyLane = lane
        var samples: [Float] = [0, 0, 0.01, 0, 0.005, 0.005]
        let expected = apply(&copy, &copyLane, samples, end: 3)
        samples.withUnsafeMutableBufferPointer { buffer in
            XCTAssertTrue(gate.apply(lane: &lane, input: UnsafeBufferPointer(buffer), output: buffer, blockEndFrame: 3))
        }
        XCTAssertEqual(samples, expected)
        XCTAssertEqual(lane.gain, copyLane.gain)
    }

    func testTransitionCountsAreCaptureOnlyDeduplicatedAndTakenOnce() {
        var gate = PushToTalkAudioGate(); gate.configure(settings())
        var input = PushToTalkLaneState(.inputCapture), system = PushToTalkLaneState(.systemCapture)
        var plugin = PushToTalkLaneState(.plugin)
        gate.setKeyTalking(true)
        _ = apply(&gate, &plugin, [1, 1])
        XCTAssertEqual(gate.takeTransitions().opens, 0)
        _ = apply(&gate, &input, [1, 1]); _ = apply(&gate, &system, [1, 1])
        XCTAssertEqual(gate.takeTransitions().opens, 1)
        gate.setKeyTalking(false)
        _ = apply(&gate, &input, [1, 1]); _ = apply(&gate, &system, [1, 1])
        XCTAssertEqual(gate.takeTransitions().closes, 1)
        let final = gate.takeTransitions()
        XCTAssertEqual(final.opens, 0); XCTAssertEqual(final.closes, 0)
    }

    func testOverflowingHangObservationCannotManufactureOpening() {
        var gate = PushToTalkAudioGate(); gate.configure(settings(trigger: .level))
        var lane = PushToTalkLaneState(.inputCapture)
        _ = apply(&gate, &lane, [0.1, 0], end: Int64.min + 1)
        XCTAssertFalse(gate.isOpen(atFrame: .max))
    }
}
