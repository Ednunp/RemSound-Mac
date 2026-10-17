import AudioSupport
import AVFoundation
import XCTest
@testable import RemSoundCore

final class AudioRingTests: XCTestCase {
    func testMultipleInputsDiscardSetupBacklogBeforeFirstSend() {
        let early = StereoRing(capacity: 4_096)
        let later = StereoRing(capacity: 4_096)
        early.write([Float](repeating: 0.125, count: 2_048 * 2))
        later.write([Float](repeating: 0.25, count: 512 * 2))
        let mix = SystemAudioMix(sources: [early, later])
        XCTAssertEqual(mix.prepareForSending(), 2_560)
        XCTAssertEqual(early.available, 0)
        XCTAssertEqual(later.available, 0)
        early.write([Float](repeating: 0.125, count: 120 * 2))
        later.write([Float](repeating: 0.25, count: 120 * 2))
        XCTAssertEqual(mix.read(120), [Float](repeating: 0.375, count: 120 * 2))
        for _ in 0..<400 {
            early.write([Float](repeating: 0.125, count: 120 * 2))
            later.write([Float](repeating: 0.25, count: 120 * 2))
            _ = mix.read(120)
        }
        XCTAssertEqual(early.available, later.available)
        XCTAssertEqual(mix.available, 0)
    }

    func testPreparingOneInputPreservesEverySample() {
        let source = StereoRing(capacity: 4)
        let samples: [Float] = [0.125, -0.125, 0.25, -0.25]
        source.write(samples)
        let mix = SystemAudioMix(sources: [source])
        XCTAssertEqual(mix.prepareForSending(), 0)
        XCTAssertEqual(mix.read(2), samples)
        XCTAssertEqual(SystemAudioMix(sources: []).prepareForSending(), 0)
    }

    func testPreparingMixAgainDoesNotDiscardLiveAudio() {
        let early = StereoRing(capacity: 4)
        let later = StereoRing(capacity: 4)
        early.write([0.125, -0.125])
        let mix = SystemAudioMix(sources: [early, later])
        XCTAssertEqual(mix.prepareForSending(), 1)
        early.write([0.25, -0.25])
        later.write([0.125, -0.125])
        XCTAssertEqual(mix.prepareForSending(), 0)
        XCTAssertEqual(mix.read(1), [0.375, -0.375])
    }

    func testFreshMixPreparesAfterStopOrReconfiguration() {
        let early = StereoRing(capacity: 4)
        let later = StereoRing(capacity: 4)
        let first = SystemAudioMix(sources: [early, later])
        _ = first.prepareForSending()
        early.write([0.25, -0.25])
        later.write([0.125, -0.125])
        let replacement = SystemAudioMix(sources: [early, later])
        XCTAssertEqual(replacement.prepareForSending(), 2)
        XCTAssertEqual(replacement.available, 0)
    }

    func testPlaybackFanoutGivesEachOutputTheSameFrames() {
        let fanout = PlaybackFanout(primary: StereoRing(capacity: 16))
        let first = fanout.addOutput()
        let second = fanout.addOutput()
        let samples: [Float] = [0.25, -0.25, 0.5, -0.5]
        fanout.write(samples)
        XCTAssertEqual(first.read(2), samples)
        XCTAssertEqual(second.read(2), samples)
        fanout.write(samples)
        XCTAssertEqual(first.read(2), samples)
        XCTAssertEqual(second.read(2), samples)
    }
    func testInterleavedCapturePreservesStereoAcrossWrap() throws {
        let ring = try XCTUnwrap(rs_ring_create(3))
        defer { rs_ring_destroy(ring) }
        var first: [Float] = [0.1, 0.2, 0.3, 0.4]
        XCTAssertEqual(rs_ring_write_interleaved(ring, &first, 2), 2)

        var left = [Float](repeating: 0, count: 1)
        var right = left
        XCTAssertEqual(rs_ring_read(ring, &left, &right, 1), 1)
        XCTAssertEqual(left, [0.1])
        XCTAssertEqual(right, [0.2])

        var second: [Float] = [0.5, 0.6, 0.7, 0.8]
        XCTAssertEqual(rs_ring_write_interleaved(ring, &second, 2), 2)
        left = [Float](repeating: 0, count: 3)
        right = left
        XCTAssertEqual(rs_ring_read(ring, &left, &right, 3), 3)
        XCTAssertEqual(left, [0.3, 0.5, 0.7])
        XCTAssertEqual(right, [0.4, 0.6, 0.8])
    }

    func testMultichannelOutputCaptureKeepsFirstStereoPair() throws {
        let ring = try XCTUnwrap(rs_ring_create(2))
        defer { rs_ring_destroy(ring) }
        var fourChannels: [Float] = [0.1, 0.2, 0.8, 0.9, 0.3, 0.4, 0.7, 0.6]
        XCTAssertEqual(rs_ring_write_interleaved_channels(ring, &fourChannels, 4, 2), 2)
        var left = [Float](repeating: 0, count: 2)
        var right = left
        XCTAssertEqual(rs_ring_read(ring, &left, &right, 2), 2)
        XCTAssertEqual(left, [0.1, 0.3])
        XCTAssertEqual(right, [0.2, 0.4])
    }
    func testSixChannelInterfaceCaptureKeepsFirstPairAndCountsFrames() throws {
        let ring = try XCTUnwrap(rs_ring_create(2))
        defer { rs_ring_destroy(ring) }
        var sixChannels: [Float] = [0.1, -0.1, 0.7, 0.8, 0.9, 1,
                                    0.2, -0.2, 0.6, 0.5, 0.4, 0.3]
        XCTAssertEqual(rs_ring_write_interleaved_channels(ring, &sixChannels, 6, 2), 2)
        var left = [Float](repeating: 0, count: 2)
        var right = left
        XCTAssertEqual(rs_ring_read(ring, &left, &right, 2), 2)
        XCTAssertEqual(left, [0.1, 0.2])
        XCTAssertEqual(right, [-0.1, -0.2])
        XCTAssertEqual(rs_ring_written_frames(ring), 2)
    }
    func testSystemCaptureCanSelectSecondStereoPair() throws {
        let ring = try XCTUnwrap(rs_ring_create(2))
        defer { rs_ring_destroy(ring) }
        var channels: [Float] = [0.1, 0.2, 0.7, 0.8, 0.3, 0.4, 0.9, 1.0]
        XCTAssertEqual(rs_ring_write_interleaved_channel_pair(
            ring, &channels, 4, 1, 2), 2)
        var left = [Float](repeating: 0, count: 2)
        var right = left
        XCTAssertEqual(rs_ring_read(ring, &left, &right, 2), 2)
        XCTAssertEqual(left, [0.7, 0.9])
        XCTAssertEqual(right, [0.8, 1.0])
        XCTAssertEqual(rs_ring_write_interleaved_channel_pair(
            ring, &channels, 4, 2, 2), 0)
    }
    func testSelectedInterfacePairsMixIntoOneStereoStream() throws {
        let ring = try XCTUnwrap(rs_ring_create(2))
        defer { rs_ring_destroy(ring) }
        var channels: [Float] = [0.1, 0.2, 0.7, 0.8, 0.3, -0.2,
                                 0.2, 0.1, 0.6, 0.5, 0.4, -0.1]
        var pairs = [0, 2]
        XCTAssertEqual(rs_ring_write_interleaved_pairs(
            ring, &channels, 6, &pairs, pairs.count, 2), 2)
        var left = [Float](repeating: 0, count: 2)
        var right = left
        XCTAssertEqual(rs_ring_read(ring, &left, &right, 2), 2)
        XCTAssertEqual(left[0], 0.4, accuracy: 0.00001)
        XCTAssertEqual(left[1], 0.6, accuracy: 0.00001)
        XCTAssertEqual(right, [0, 0])
    }
    func testMonoInputTapCopiesSignalToBothSentChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        buffer.floatChannelData?[0][0] = 0.1
        buffer.floatChannelData?[0][1] = 0.3
        let ring = StereoRing(capacity: 2)
        ring.write(buffer)
        XCTAssertEqual(ring.read(2), [0.1, 0.1, 0.3, 0.3])
    }
    func testInterleavedMonoInputAlsoCopiesSignalToBothChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let data = try XCTUnwrap(buffer.audioBufferList.pointee.mBuffers.mData)
            .assumingMemoryBound(to: Float.self)
        data[0] = 0.2
        data[1] = 0.4
        let ring = StereoRing(capacity: 2)
        ring.write(buffer)
        XCTAssertEqual(ring.read(2), [0.2, 0.2, 0.4, 0.4])
    }
    func testBuiltInMicrophoneFallbackCopiesLeftOnlyBufferToBothOutputs() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        buffer.floatChannelData?[0][0] = 0.2
        buffer.floatChannelData?[0][1] = 0.4
        buffer.floatChannelData?[1][0] = 0
        buffer.floatChannelData?[1][1] = 0
        let ring = StereoRing(capacity: 2)
        StereoRing.write(buffer, to: ring.raw, duplicateFirstChannel: true)
        XCTAssertEqual(ring.read(2), [0.2, 0.2, 0.4, 0.4])
    }
    func testCaptureOverflowCountsWholeDroppedBlocks() throws {
        let ring = try XCTUnwrap(rs_ring_create(2))
        defer { rs_ring_destroy(ring) }
        var first: [Float] = [0, 0, 0, 0]
        var overflow: [Float] = [1, 1]
        XCTAssertEqual(rs_ring_write_interleaved(ring, &first, 2), 2)
        XCTAssertEqual(rs_ring_write_interleaved(ring, &overflow, 1), 0)
        XCTAssertEqual(rs_ring_dropped_frames(ring), 1)
    }
    func testDiscardOldestKeepsNewestCaptureFrames() throws {
        let ring = try XCTUnwrap(rs_ring_create(5))
        defer { rs_ring_destroy(ring) }
        var left: [Float] = [0.1, 0.2, 0.3, 0.4]
        var right: [Float] = [1.1, 1.2, 1.3, 1.4]
        XCTAssertEqual(rs_ring_write(ring, &left, &right, 4), 4)
        XCTAssertEqual(rs_ring_discard(ring, 3), 3)
        var heardLeft = [Float](repeating: 0, count: 1)
        var heardRight = heardLeft
        XCTAssertEqual(rs_ring_read(ring, &heardLeft, &heardRight, 1), 1)
        XCTAssertEqual(heardLeft, [0.4])
        XCTAssertEqual(heardRight, [1.4])
    }

    func testSelectedSystemOutputsMixWithoutWaitingForSilentOutput() {
        let first = StereoRing(capacity: 4)
        let second = StereoRing(capacity: 4)
        first.write([0.25, 0, 0.5, 0])
        second.write([0, 0.25])
        let mix = SystemAudioMix(sources: [first, second])
        XCTAssertEqual(mix.available, 2)
        XCTAssertEqual(mix.read(2), [0.25, 0.25, 0.5, 0])
    }
    func testSelectedInputsMixWithoutBlockingOnIdleInput() {
        let microphone = StereoRing(capacity: 4)
        let interface = StereoRing(capacity: 4)
        microphone.write([0.2, 0.2, 0.3, 0.3])
        interface.write([0.1, -0.1])
        let mix = SystemAudioMix(sources: [microphone, interface])
        XCTAssertEqual(mix.available, 2)
        XCTAssertEqual(mix.read(2), [0.3, 0.1, 0.3, 0.3])
        microphone.write([0.4, 0.4])
        XCTAssertEqual(mix.read(1), [0.4, 0.4])
    }
}
