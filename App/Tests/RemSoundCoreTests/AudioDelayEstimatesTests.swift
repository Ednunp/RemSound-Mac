import CoreAudio
import XCTest
@testable import RemSoundCore

final class AudioDelayEstimatesTests: XCTestCase {
    private func device(_ direction: AudioDeviceDirection, buffer: Double? = 128, deviceLatency: Double? = 96,
                        safety: Double? = 32, streams: [DeviceConfigurationSnapshot.Stream]? = nil,
                        physicalRate: Double? = 48_000) -> DeviceConfigurationSnapshot {
        .init(id: 7, name: "Card", direction: direction, nominalRate: 48_000, actualRate: 47_976,
              bufferFrames: buffer, deviceLatencyFrames: deviceLatency, safetyOffsetFrames: safety,
              presentationLatencySeconds: 0.999,
              streams: streams ?? [.init(id: 9, virtualRate: 48_000, physicalRate: physicalRate, channels: 2, latencyFrames: 24)])
    }

    func testHardwareAndIOEstimatesUseWorstStreamNominalUnitsAndNeverAddAVDelay() throws {
        let snapshot = device(.input, streams: [
            .init(id: 1, virtualRate: 48_000, physicalRate: 48_000, channels: 2, latencyFrames: 24),
            .init(id: 2, virtualRate: 48_000, physicalRate: 48_000, channels: 4, latencyFrames: 48)])
        let estimate = try XCTUnwrap(snapshot.delayEstimate)
        XCTAssertEqual(estimate.hardwareSeconds, 144.0 / 48_000, accuracy: 1e-12)
        XCTAssertEqual(estimate.ioStagingSeconds, 304.0 / 48_000, accuracy: 1e-12)
        XCTAssertTrue(snapshot.logDescription.contains("IO component estimate 6.333"))
        XCTAssertTrue(snapshot.logDescription.contains("not added to AV presentation delay"))
        let zero = try XCTUnwrap(device(.input, deviceLatency: 0, safety: 0,
            streams: [.init(id: 1, virtualRate: 48_000, physicalRate: 48_000, channels: 1, latencyFrames: 0)]).delayEstimate)
        XCTAssertEqual(zero.hardwareSeconds, 0)
        XCTAssertEqual(zero.ioStagingSeconds, 128.0 / 48_000)
    }

    func testUnknownInvalidOrMixedRateComponentsDoNotBecomeACompleteEstimate() {
        XCTAssertNil(device(.output, buffer: nil).delayEstimate)
        XCTAssertNil(device(.output, deviceLatency: nil).delayEstimate)
        XCTAssertNil(device(.output, safety: -.infinity).delayEstimate)
        XCTAssertNil(device(.output, physicalRate: nil).delayEstimate)
        XCTAssertNil(device(.output, physicalRate: 96_000).delayEstimate)
        XCTAssertNil(device(.output, streams: []).delayEstimate)
        XCTAssertNil(device(.output, streams: [.init(id: 1, virtualRate: 48_000,
            physicalRate: 48_000, channels: 2, latencyFrames: nil)]).delayEstimate)
    }

    func testComparisonReplacesAlreadyIncludedInputAndUsesWorstOutputInsteadOfAddingAVAgain() throws {
        let inputs = [device(.input, buffer: 840, deviceLatency: 96, safety: 0)] // 20 ms
        let outputs = [device(.output, buffer: 360, deviceLatency: 96, safety: 0), // 10 ms
                       device(.output, buffer: 1_320, deviceLatency: 96, safety: 0)] // 30 ms
        let estimates = AudioDelayEstimates(inputs: inputs, outputs: outputs,
            expectedInputDevices: 1, expectedOutputDevices: 2)
        let comparison = try XCTUnwrap(estimates.compare(source: .selectedInputs, captureToReturnMs: 40,
            includedInputMs: 5, receiveQueueMs: 20, outputQueueMs: 3, originalOutputMs: 2, inputBufferAlreadyIncludedMs: 7))
        XCTAssertEqual(comparison.originalTotalMs, 65)
        XCTAssertEqual(comparison.ioComponentTotalMs, 101)
        XCTAssertEqual(comparison.inputBufferAlreadyIncludedMs, 7)
        XCTAssertEqual(comparison.inputIOMs, 20)
        XCTAssertEqual(comparison.worstOutputIOMs, 30)
        XCTAssertTrue(comparison.logDescription.contains("not an acoustic measurement"))
        XCTAssertTrue(comparison.logDescription.contains("all advertised streams"))
    }

    func testComparisonRefusesMissingDevicesAndUnknownSystemOrDAWInputOrigins() {
        let input = device(.input), output = device(.output)
        func comparison(_ estimates: AudioDelayEstimates, source: AudioDelayEstimates.Source = .selectedInputs,
                        overlap: Double? = 0) -> AudioDelayEstimates.Comparison? {
            estimates.compare(source: source, captureToReturnMs: 40, includedInputMs: 5,
                receiveQueueMs: 20, outputQueueMs: 3, originalOutputMs: 2, inputBufferAlreadyIncludedMs: overlap)
        }
        XCTAssertNil(comparison(.init(inputs: [input], outputs: [output], expectedInputDevices: 2, expectedOutputDevices: 1)))
        XCTAssertNil(comparison(.init(inputs: [input], outputs: [output], expectedInputDevices: 1, expectedOutputDevices: 2)))
        XCTAssertNil(comparison(.init(inputs: [], outputs: [output], expectedInputDevices: 0, expectedOutputDevices: 1)))
        let complete = AudioDelayEstimates(inputs: [input], outputs: [output], expectedInputDevices: 1, expectedOutputDevices: 1)
        XCTAssertNil(comparison(complete, overlap: nil), "The worker-derived queue origin has not established its IO-buffer overlap")
        XCTAssertNil(comparison(complete, overlap: .nan))
        XCTAssertNil(comparison(complete, overlap: -1))
        XCTAssertNil(comparison(complete, overlap: 3), "Overlap cannot exceed the reported input IO buffer")
        XCTAssertNil(comparison(complete, source: .systemOrApplications))
        XCTAssertNil(comparison(complete, source: .dawBridge))
        XCTAssertNil(comparison(complete, source: .unknown))
        XCTAssertNil(complete.compare(source: .selectedInputs, captureToReturnMs: 4, includedInputMs: 5,
            receiveQueueMs: 20, outputQueueMs: 3, originalOutputMs: 2, inputBufferAlreadyIncludedMs: 0))
    }
}
