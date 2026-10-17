import AudioSupport
import Foundation
import XCTest
@testable import RemSoundCore

final class CaptureInputClockTests: XCTestCase {
    private var previousKeepingInTime = true
    override func setUp() {
        super.setUp()
        previousKeepingInTime = ClockKeeping.on
        ClockKeeping.on = true
    }
    override func tearDown() {
        ClockKeeping.on = previousKeepingInTime
        super.tearDown()
    }

    func testMixTargetFollowsCallbackAndPacketChanges() {
        let rings = [StereoRing(capacity: 48_000), StereoRing(capacity: 48_000)]
        var callback = CaptureInputClocks.Callback(sequence: 1, frames: 512)
        let mix = SystemAudioMix(sources: rings, captureCallbacks: { [callback, callback] })
        for ring in rings { ring.write([Float](repeating: 0.125, count: 4096 * 2)) }
        _ = mix.read(120, now: 0)
        XCTAssertEqual(mix.inputClockFigures.first?.targetFrames, 512)
        callback = .init(sequence: 2, frames: 64)
        _ = mix.read(120, now: 0.2)
        XCTAssertEqual(mix.inputClockFigures.first?.targetFrames, 512)
        callback = .init(sequence: 3, frames: 64)
        _ = mix.read(120, now: 0.6)
        XCTAssertEqual(mix.inputClockFigures.first?.targetFrames, 290)
        _ = mix.read(64, now: 0.61)
        XCTAssertEqual(mix.inputClockFigures.first?.targetFrames, 178)
        callback = .init(sequence: 4, frames: 1024)
        _ = mix.read(64, now: 0.62)
        XCTAssertEqual(mix.inputClockFigures.first?.targetFrames, 1024)
        XCTAssertTrue(mix.inputClockFigures.allSatisfy { !$0.tracking && $0.ratio == 1 })
    }

    func testCallbackPeakFollowsBufferChangeWithoutOscillatingBetweenBlocks() {
        var peak = CaptureCallbackPeak()
        XCTAssertEqual(peak.observe(.init(sequence: 1, frames: 512), now: 0), 512)
        XCTAssertEqual(peak.observe(.init(sequence: 2, frames: 64), now: 0.2), 512)
        XCTAssertEqual(peak.observe(.init(sequence: 3, frames: 512), now: 0.3), 512)
        XCTAssertEqual(peak.observe(.init(sequence: 4, frames: 64), now: 0.6), 512)
        XCTAssertEqual(peak.observe(.init(sequence: 5, frames: 64), now: 0.81), 64)
        XCTAssertEqual(peak.observe(.init(sequence: 5, frames: 64), now: 1.32), 0,
            "Repeated observation of an old callback must not make an idle input current")
        XCTAssertEqual(peak.observe(.init(sequence: 1, frames: 128), now: 1.33), 128,
            "A replacement counter starts a fresh observation")
    }

    func testTargetUsesActualCallbackAndPacketGeometry() {
        XCTAssertEqual(CaptureInputClocks.target(callbackFrames: 32, packetFrames: 64), 178)
        XCTAssertEqual(CaptureInputClocks.target(callbackFrames: 32, packetFrames: 120), 290)
        XCTAssertEqual(CaptureInputClocks.target(callbackFrames: 512, packetFrames: 120), 512)
        XCTAssertEqual(CaptureInputClocks.target(callbackFrames: 1024, packetFrames: 64), 1024)
    }

    func testDiagnosticsDistinguishUnknownMeasurementFromAppliedRatio() {
        let starting = CaptureInputClocks.Figures(callbackFrames: 0, targetFrames: 178,
            tracking: false, primed: false, keepingInTime: true, ratio: 1, ppm: 0, rejected: 0)
        XCTAssertTrue(starting.logDescription(name: "Input").contains("normalized callback=unavailable"))
        XCTAssertTrue(starting.logDescription(name: "Input").contains("measured=unavailable"))
        let tracking = CaptureInputClocks.Figures(callbackFrames: 512, targetFrames: 512,
            tracking: true, primed: true, keepingInTime: true, ratio: 1.0004, ppm: 300, rejected: 1)
        let text = tracking.logDescription(name: "Input")
        XCTAssertTrue(text.contains("measured=+300.0 ppm"))
        XCTAssertTrue(text.contains("applied input/output ratio=1.000400000"))
    }

    func testHardwareObservationRequiresCoherentNormalizedPhysicalInput() {
        let ring = StereoRing(capacity: 4096)
        XCTAssertEqual(DeviceAudio.captureCallback(ring).frames, 0)
        for (rate, origin, expected) in [(48_000.0, UInt32(RS_CAPTURE_HAL), 512),
            (48_000.0, UInt32(RS_CAPTURE_AV_TAP), 512),
            (96_000.0, UInt32(RS_CAPTURE_HAL), 0),
            (48_000.0, UInt32(RS_CAPTURE_PROCESS_TAP), 0)] {
            ring.write([Float](repeating: 0.25, count: 512 * 2))
            rs_ring_note_capture(ring.raw, 1, 1, 0, 0, 512, 512, rate, origin)
            XCTAssertEqual(DeviceAudio.captureCallback(ring).frames, expected)
        }
    }

    func testGenericTapMixAndSingleInputKeepOriginalSamples() {
        let a = StereoRing(capacity: 4096), b = StereoRing(capacity: 4096)
        let samples: [Float] = [0.125, -0.125, 0.25, -0.25]
        a.write(samples)
        let generic = SystemAudioMix(sources: [a, b])
        XCTAssertEqual(generic.read(2, now: 0), samples)
        a.write(samples)
        let single = SystemAudioMix(sources: [a], captureCallbacks: {
            [.init(sequence: 1, frames: 512)]
        })
        XCTAssertEqual(single.prepareForSending(), 0)
        XCTAssertEqual(single.read(2, now: 0), samples)
        XCTAssertTrue(single.inputClockFigures.isEmpty)
    }

    func testUnavailableInputHasBoundedPrimingWait() {
        let a = StereoRing(capacity: 4096), b = StereoRing(capacity: 4096)
        let mix = SystemAudioMix(sources: [a, b], captureCallbacks: {
            [.init(sequence: 1, frames: 512), .unavailable]
        })
        a.write([Float](repeating: 0.25, count: 2048 * 2))
        XCTAssertEqual(mix.read(120, now: 0), [Float](repeating: 0, count: 240))
        XCTAssertEqual(mix.read(120, now: 0.101), [Float](repeating: 0.25, count: 240))
    }

    func testKeepInTimeOffBypassesAnAcquiredController() {
        let previous = ClockKeeping.on
        defer { ClockKeeping.on = previous }
        ClockKeeping.on = true
        let rings = [StereoRing(capacity: 48_000), StereoRing(capacity: 48_000)]
        let controls = [StereoRing(capacity: 48_000), StereoRing(capacity: 48_000)]
        var revisions = [UInt64(0), UInt64(0)]
        let mix = SystemAudioMix(sources: rings, captureCallbacks: {
            revisions.map { .init(sequence: $0, frames: 512) }
        })
        let periods = [512.0 / 48_014.4, 512.0 / 47_985.6]
        var next = periods, pacer = CapturePacer(), blocks = [0, 0]
        var compared = 0, mismatches = 0, trackedWhileOff = 0, missingAfterReenable = [0, 0]
        for tick in 0..<120_000 {
            let now = Double(tick) / 1000
            if tick == 40_000 {
                XCTAssertTrue(mix.inputClockFigures.allSatisfy(\.tracking))
                ClockKeeping.on = false
                // Align the direct-read oracle to the exact queued samples at the switch.
                for i in 0..<2 { _ = controls[i].discard(controls[i].available - rings[i].available) }
            }
            if tick == 80_000 { ClockKeeping.on = true }
            for i in 0..<2 {
                while next[i] <= now {
                    let samples: [Float] = (0..<512).flatMap { f in
                        let x = tick >= 80_000 ? Float(0.25) : Float((blocks[i] * 512 + f) % 107) / 216
                        return i == 0 ? [x, 0] : [0, x]
                    }
                    rings[i].write(samples); controls[i].write(samples)
                    revisions[i] += 1; blocks[i] += 1
                    next[i] += periods[i]
                }
            }
            let packets = pacer.packetCount(now: now, bufferedFrames: mix.available,
                packetFrames: 120, sourceCount: 2)
            for _ in 0..<packets {
                let output = mix.read(120, now: now)
                if tick >= 40_000 && tick < 80_000 {
                    let expected = zip(controls[0].read(120), controls[1].read(120)).map(+)
                    compared += 120
                    if output != expected { mismatches += 1 }
                    if mix.inputClockFigures.contains(where: { $0.tracking || $0.ratio != 1 }) { trackedWhileOff += 1 }
                } else {
                    for i in 0..<2 { _ = controls[i].discard(max(0, controls[i].available - 4096)) }
                }
                if tick >= 100_000 {
                    for i in 0..<2 {
                        for f in 0..<120 where output[2 * f + i] < 0.249 { missingAfterReenable[i] += 1 }
                    }
                }
            }
        }
        XCTAssertEqual(compared, 40 * 48_000)
        XCTAssertEqual(mismatches, 0, "Off must stay sample-for-sample unchanged for the whole interval")
        XCTAssertEqual(trackedWhileOff, 0)
        XCTAssertEqual(missingAfterReenable, [0, 0])
        XCTAssertTrue(mix.inputClockFigures.allSatisfy(\.tracking))
    }

    func testIndependentInputsStayAlignedAtFixedWireRate() {
        for sizes in [[64, 64], [512, 512], [32, 512], [1024, 128]] {
            for packet in [64, 120] {
                let rings = [StereoRing(capacity: 48_000), StereoRing(capacity: 48_000)]
                var revisions = [UInt64(0), UInt64(0)]
                let mix = SystemAudioMix(sources: rings, captureCallbacks: {
                    (0..<2).map { .init(sequence: revisions[$0], frames: sizes[$0]) }
                })
                let periods = [Double(sizes[0]) / 48_014.4, Double(sizes[1]) / 47_985.6]
                var next = [periods[0], periods[1] + 0.003]
                let blocks: [[Float]] = (0..<2).map { i in
                    (0..<sizes[i]).flatMap { _ in i == 0 ? [Float(0.25), 0] : [0, Float(0.25)] }
                }
                var pacer = CapturePacer(), missing = [0, 0], steadyFrames = 0
                _ = mix.prepareForSending()
                for tick in 0..<120_000 {
                    let now = Double(tick) / 1000
                    for i in 0..<2 {
                        while next[i] <= now {
                            rings[i].write(blocks[i]); revisions[i] += 1
                            next[i] += periods[i]
                        }
                    }
                    _ = mix.trimStale(packetFrames: packet)
                    let packets = pacer.packetCount(now: now, bufferedFrames: mix.available,
                        packetFrames: packet, sourceCount: 2)
                    for _ in 0..<packets {
                        let block = mix.read(packet, now: now)
                        if tick >= 40_000 {
                            steadyFrames += packet
                            for i in 0..<2 {
                                for f in 0..<packet where block[2 * f + i] < 0.249 { missing[i] += 1 }
                            }
                        }
                    }
                }
                XCTAssertEqual(steadyFrames, 3_840_000)
                XCTAssertEqual(missing, [0, 0], "\(sizes), \(packet)")
                XCTAssertLessThanOrEqual(abs(rings[0].available - rings[1].available), sizes.max()! + packet)
                XCTAssertEqual(mix.inputClockFigures.first?.targetFrames,
                    CaptureInputClocks.target(callbackFrames: sizes.max()!, packetFrames: packet))
            }
        }
    }
}
