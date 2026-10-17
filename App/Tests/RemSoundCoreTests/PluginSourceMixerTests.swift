import Foundation
import XCTest
@testable import RemSoundCore
@testable import RemSoundJam

final class PluginSourceMixerTests: XCTestCase {
    private let generation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let wrong = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private typealias Mixer = PluginSourceMixer<Int>
    private func block(_ frames: Int = 240, _ value: Float = 0.25) -> [Float] {
        Array(repeating: [value, -value], count: frames).flatMap { $0 }
    }
    private func feed(_ mixer: Mixer, _ key: Int, _ now: Double, frames: Int = 240, value: Float = 0.25) -> Mixer.Result {
        mixer.offer(block(frames, value), from: key, generation: generation, now: now)
    }
    func testSecondaryStartsEmptyWithHalfSecondFixedCapacity() {
        let lane = PluginSecondaryLane()
        XCTAssertEqual(lane.snapshot.bufferedFrames, 0); XCTAssertFalse(lane.snapshot.primed)
        XCTAssertEqual(lane.snapshot.targetFrames, 576); XCTAssertEqual(PluginSecondaryLane.capacityFrames, 24_000)
        XCTAssertEqual(PluginSecondaryLane.maximumFrames, 4096)
    }
    func testUnprimedPullPreservesActualQueuedSamples() {
        let lane = PluginSecondaryLane(); XCTAssertTrue(lane.feed(block(), now: 0))
        let output = lane.pull(frames: 240, now: 0)
        XCTAssertEqual(output, [Float](repeating: 0, count: 480))
        XCTAssertEqual(lane.snapshot.bufferedFrames, 240); XCTAssertFalse(lane.snapshot.primed)
    }
    func testPrimedPullUsesActualResamplerAndKeepsStereoShape() {
        let lane = PluginSecondaryLane(); XCTAssertTrue(lane.feed(block(960), now: 0))
        XCTAssertEqual(lane.pull(frames: 240, now: 0), block())
        XCTAssertTrue(lane.snapshot.primed); XCTAssertEqual(lane.snapshot.bufferedFrames, 718)
        XCTAssertEqual(lane.snapshot.shortFrames, 0)
    }
    func testLargeDriverDoesNotPrimeFromInsufficientCushion() {
        let lane = PluginSecondaryLane(); XCTAssertTrue(lane.feed(block(576), now: 0))
        XCTAssertEqual(lane.pull(frames: 4096, now: 0), [Float](repeating: 0, count: 8192))
        XCTAssertEqual(lane.snapshot.bufferedFrames, 576)
        XCTAssertTrue(lane.feed(block(4096), now: 0.1))
        XCTAssertEqual(lane.pull(frames: 4096, now: 0.1), block(4096))
        XCTAssertEqual(lane.snapshot.shortFrames, 0)
    }
    func testFeedBoundsRefuseBeforeClockOrRingChanges() {
        let lane = PluginSecondaryLane(); XCTAssertTrue(lane.feed(block(), now: 0))
        for samples in [[], [Float(1)], block(4097), [Float.nan, 0], [Float.infinity, 0]] {
            XCTAssertFalse(lane.feed(samples, now: .nan))
        }
        XCTAssertNil(lane.failure); XCTAssertEqual(lane.snapshot.bufferedFrames, 240)
        XCTAssertTrue(lane.feed(block(), now: 0))
    }
    func testPullBoundsRefuseBeforeClockOrRingChanges() {
        let lane = PluginSecondaryLane(); XCTAssertTrue(lane.feed(block(960), now: 0))
        for frames in [0, -1, 4097, Int.max] { XCTAssertNil(lane.pull(frames: frames, now: .nan)) }
        XCTAssertNil(lane.failure); XCTAssertEqual(lane.snapshot.bufferedFrames, 960)
    }
    func testCapacityDropsOnlyOldestFramesBeforeCopy() {
        let lane = PluginSecondaryLane()
        for index in 0..<6 { XCTAssertTrue(lane.feed(block(4096, Float(index)), now: 0)) }
        XCTAssertEqual(lane.snapshot.bufferedFrames, 24_000); XCTAssertEqual(lane.snapshot.droppedFrames, 576)
        let output = lane.pull(frames: 4096, now: 0)
        XCTAssertEqual(output?.count, 8192); XCTAssertEqual(output?.first, 0)
        XCTAssertEqual(output?[3520 * 2], 1)
    }
    func testCapacityCutCannotInterpolatePreviouslyHeldSound() {
        let lane = PluginSecondaryLane(); _ = lane.feed(block(960), now: 0); _ = lane.pull(frames: 240, now: 0)
        for _ in 0..<6 { XCTAssertTrue(lane.feed(block(4096, 0.75), now: 0.1)) }
        XCTAssertEqual(lane.pull(frames: 240, now: 0.1), block(240, 0.75))
        XCTAssertGreaterThan(lane.snapshot.droppedFrames, 0)
    }
    func testShortReadZeroPadsWithoutInventingProducedFrames() {
        let lane = PluginSecondaryLane(); _ = lane.feed(block(960), now: 0); _ = lane.pull(frames: 240, now: 0)
        let output = lane.pull(frames: 4096, now: 0.1)
        XCTAssertEqual(output?.count, 8192); XCTAssertEqual(output?.last, 0)
        XCTAssertGreaterThan(lane.snapshot.shortFrames, 0); XCTAssertEqual(lane.snapshot.bufferedFrames, 0)
    }
    func testInvalidClockClosesLaneWithoutRecovery() {
        for bad in [Double.nan, Double.infinity, Double.greatestFiniteMagnitude, -1, 0.5] {
            let lane = PluginSecondaryLane(); _ = lane.feed(block(960), now: 1)
            XCTAssertNil(lane.pull(frames: 240, now: bad)); XCTAssertEqual(lane.failure, .invalidClock)
            XCTAssertFalse(lane.feed(block(), now: 2)); XCTAssertEqual(lane.snapshot.bufferedFrames, 0)
        }
    }
    func testInterpolationArithmeticFailureIsNotPublishedAsAudio() {
        let lane = PluginSecondaryLane()
        let samples = (0..<960).flatMap { index in [Float](repeating: index.isMultiple(of: 2) ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude, count: 2) }
        XCTAssertTrue(lane.feed(samples, now: 0)); XCTAssertNil(lane.pull(frames: 240, now: 0))
        XCTAssertEqual(lane.failure, .invalidResampler)
    }
    func testAdaptiveTargetMatchesExistingPrivateJamRuleFromActualPulls() {
        for frames in [32, 480, 512, 640, 960, 2048, 4096] {
            let lane = PluginSecondaryLane()
            for _ in 0..<3 { XCTAssertTrue(lane.feed(block(4000), now: 0)) }
            XCTAssertNotNil(lane.pull(frames: frames, now: 0))
            for index in 1...101 {
                let now = Double(index) / 10
                XCTAssertTrue(lane.feed(block(frames), now: now)); XCTAssertNotNil(lane.pull(frames: frames, now: now))
            }
            XCTAssertEqual(lane.snapshot.targetFrames, OutputCushion.next(current: 12, averageFrames: Double(frames)) * 48)
        }
    }
    func testMatchedSyntheticClocksAcquireExistingDriftMeter() {
        let lane = PluginSecondaryLane(); _ = lane.feed(block(960), now: 0); _ = lane.pull(frames: 240, now: 0)
        for index in 1...4400 {
            let now = Double(index) * 0.005
            XCTAssertTrue(lane.feed(block(), now: now)); XCTAssertNotNil(lane.pull(frames: 240, now: now))
        }
        XCTAssertTrue(lane.snapshot.tracking); XCTAssertGreaterThan(lane.snapshot.acceptedWindows, 0)
        XCTAssertEqual(lane.snapshot.clockRatio, 1, accuracy: 0.000001)
        XCTAssertEqual(lane.snapshot.droppedFrames, 0); XCTAssertLessThanOrEqual(lane.snapshot.bufferedFrames, 24_000)
    }
    func testFasterAndSlowerSyntheticSourcesMoveRatioInMeasuredDirection() {
        for produced in [239, 241] {
            let lane = PluginSecondaryLane()
            for _ in 0..<3 { _ = lane.feed(block(4000), now: 0) }
            _ = lane.pull(frames: 240, now: 0)
            for index in 1...4400 {
                let now = Double(index) * 0.005
                XCTAssertTrue(lane.feed(block(produced), now: now)); XCTAssertNotNil(lane.pull(frames: 240, now: now))
            }
            XCTAssertTrue(lane.snapshot.tracking)
            if produced < 240 { XCTAssertLessThan(lane.snapshot.clockRatio, 1) }
            else { XCTAssertGreaterThan(lane.snapshot.clockRatio, 1) }
            XCTAssertEqual(lane.snapshot.droppedFrames, 0)
        }
    }
    func testFirstCompletedWindowIsDiscardedBeforeApplyingMeasuredRatio() {
        let lane = PluginSecondaryLane()
        for _ in 0..<3 { _ = lane.feed(block(4000), now: 0) }
        _ = lane.pull(frames: 240, now: 0)
        for index in 1...2200 {
            let now = Double(index) * 0.005
            _ = lane.feed(block(241), now: now); _ = lane.pull(frames: 240, now: now)
        }
        XCTAssertTrue(lane.snapshot.discardedStartupWindow)
        XCTAssertFalse(lane.snapshot.tracking); XCTAssertEqual(lane.snapshot.clockRatio, 1)
    }
    func testStallDoesNotInventAClockMeasurement() {
        let lane = PluginSecondaryLane(); _ = lane.feed(block(960), now: 0); _ = lane.pull(frames: 240, now: 0)
        _ = lane.feed(block(), now: 30); _ = lane.pull(frames: 240, now: 30)
        XCTAssertFalse(lane.snapshot.tracking); XCTAssertEqual(lane.snapshot.clockRatio, 1)
    }
    func testSingleSourceReturnsExactInputWithoutSecondaryFactory() {
        let mixer = Mixer(generation: generation), input = block()
        let result = mixer.offer(input, from: 1, generation: generation, now: 0)
        XCTAssertEqual(result.samples, input); XCTAssertTrue(result.state?.singleSourceDirect == true)
        XCTAssertEqual(mixer.secondaryCount, 0); XCTAssertNil(result.failure)
    }
    func testSecondaryFeedsOnlyItsRingAndDriverSumsWithoutConcatenating() {
        let mixer = Mixer(generation: generation); _ = feed(mixer, 1, 0)
        XCTAssertNil(feed(mixer, 2, 0, frames: 960, value: 0.5).samples)
        let result = feed(mixer, 1, 0)
        XCTAssertEqual(result.samples, block(240, 0.75)); XCTAssertEqual(result.samples?.count, 480)
        XCTAssertEqual(mixer.secondaryCount, 1); XCTAssertEqual(mixer.snapshot(2)?.bufferedFrames, 718)
    }
    func testThreeSourcesSumOnOneDriverBlock() {
        let mixer = Mixer(generation: generation); _ = feed(mixer, 1, 0, value: 0.1)
        _ = feed(mixer, 2, 0, frames: 960, value: 0.2); _ = feed(mixer, 3, 0, frames: 960, value: 0.3)
        let result = feed(mixer, 1, 0, value: 0.1)
        XCTAssertEqual(result.samples?.count, 480)
        XCTAssertEqual(result.samples?.first ?? 0, 0.6, accuracy: 0.000001)
        XCTAssertEqual(mixer.sourceCount, 3)
    }
    func testHandoverDiscardsNewDriversOldQueuedAudio() {
        let mixer = Mixer(generation: generation); _ = feed(mixer, 1, 0)
        _ = feed(mixer, 2, 0, frames: 960, value: 0.5)
        let result = feed(mixer, 2, 0.251, value: 0.75)
        XCTAssertEqual(result.samples, block(240, 0.75)); XCTAssertEqual(result.state?.driver?.key, 2)
        XCTAssertNil(mixer.snapshot(2)); XCTAssertEqual(mixer.secondaryCount, 0)
        XCTAssertNil(feed(mixer, 1, 0.3).samples); XCTAssertEqual(mixer.secondaryCount, 1)
    }
    func testExpiryDropsSecondaryBeforeSingleSourceOutput() {
        let mixer = Mixer(generation: generation); _ = feed(mixer, 1, 0); _ = feed(mixer, 2, 0, frames: 960)
        let result = feed(mixer, 1, 2)
        XCTAssertEqual(result.samples, block()); XCTAssertEqual(mixer.secondaryCount, 0)
        XCTAssertTrue(result.state?.singleSourceDirect == true)
    }
    func testInvalidFramesAndStaleGenerationDoNotTouchExistingMixer() {
        let mixer = Mixer(generation: generation); _ = feed(mixer, 1, 0); _ = feed(mixer, 2, 0, frames: 960)
        let before = mixer.snapshot(2)?.bufferedFrames
        XCTAssertEqual(mixer.offer([.nan, 0], from: 3, generation: generation, now: .nan).failure, .invalidSamples)
        XCTAssertNotNil(mixer.offer(block(), from: 3, generation: wrong, now: .nan).failure)
        XCTAssertEqual(mixer.snapshot(2)?.bufferedFrames, before); XCTAssertFalse(mixer.isClosed)
    }
    func testStopClearsMemoryAndCannotResume() {
        let mixer = Mixer(generation: generation); _ = feed(mixer, 1, 0); _ = feed(mixer, 2, 0, frames: 960)
        XCTAssertEqual(mixer.stop(generation: wrong).failure, .staleGeneration); XCTAssertEqual(mixer.secondaryCount, 1)
        XCTAssertEqual(mixer.stop(generation: generation).retired.count, 2); XCTAssertEqual(mixer.secondaryCount, 0)
        XCTAssertNil(feed(mixer, 1, 1).samples); XCTAssertTrue(mixer.isClosed)
    }
    func testReleasedVisitCannotRetireReplacementMixerSource() {
        let mixer = Mixer(generation: generation)
        guard let old = feed(mixer, 1, 0).state?.visit else { return XCTFail("missing old visit") }
        let next = feed(mixer, 1, 2)
        XCTAssertEqual(mixer.retire(old).failure, .staleVisit)
        XCTAssertEqual(mixer.currentDriver, next.state?.visit)
    }
    func testSecondaryArithmeticFailureClosesWholeMemoryOwner() {
        let mixer = Mixer(generation: generation); _ = feed(mixer, 1, 0)
        let samples = (0..<960).flatMap { index in [Float](repeating: index.isMultiple(of: 2) ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude, count: 2) }
        XCTAssertNil(mixer.offer(samples, from: 2, generation: generation, now: 0).failure)
        let result = feed(mixer, 1, 0)
        XCTAssertNil(result.samples); XCTAssertNotNil(result.failure); XCTAssertTrue(mixer.isClosed)
        XCTAssertEqual(mixer.secondaryCount, 0)
    }
    func testFiniteWideSummationDoesNotClampBeforeCancellation() {
        let mixer = Mixer(generation: generation); let high = Float.greatestFiniteMagnitude
        _ = feed(mixer, 1, 0, value: high)
        _ = feed(mixer, 2, 0, frames: 960, value: high)
        _ = feed(mixer, 3, 0, frames: 960, value: -high)
        let result = feed(mixer, 1, 0, value: high)
        XCTAssertNil(result.failure); XCTAssertEqual(result.samples?.first, high)
        XCTAssertTrue(result.samples?.allSatisfy(\.isFinite) == true)
    }
    func testPolicyQuotaBoundsSecondaryMemory() {
        let mixer = Mixer(generation: generation); _ = feed(mixer, 0, 0)
        for key in 1..<64 { XCTAssertNil(feed(mixer, key, 0).failure) }
        XCTAssertEqual(mixer.sourceCount, 64); XCTAssertEqual(mixer.secondaryCount, 63)
        XCTAssertNotNil(feed(mixer, 999, 0).failure); XCTAssertEqual(mixer.secondaryCount, 63)
    }
    func testFiniteMixerChurnDoesNotRetainRetiredSecondaries() {
        let mixer = Mixer(generation: generation)
        for index in 0..<200 {
            let now = Double(index) * 2
            _ = feed(mixer, 1, now); _ = feed(mixer, 2, now, frames: 960)
            XCTAssertEqual(feed(mixer, 1, now).samples, block(240, 0.5))
            XCTAssertLessThanOrEqual(mixer.secondaryCount, 1)
        }
    }
}
