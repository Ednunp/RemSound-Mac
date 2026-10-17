import AudioToolbox
import CoreAudio
import XCTest
@testable import RemSoundCore

final class DeviceConfigurationDiagnosticsTests: XCTestCase {
    func testEachDirectionUsesItsOwnHardwareDelayAndKeepsRatesDistinct() {
        var requests = [(AudioObjectPropertySelector, AudioObjectPropertyScope)]()
        let reader = DeviceConfigurationReader(readScalar: { id, selector, scope in
            XCTAssertEqual(id, 7)
            requests.append((selector, scope))
            switch selector {
            case kAudioDevicePropertyNominalSampleRate: return 48_000
            case kAudioDevicePropertyActualSampleRate: return 47_976
            case kAudioDevicePropertyBufferFrameSize: return 128
            case kAudioDevicePropertyLatency: return scope == kAudioObjectPropertyScopeInput ? 96 : 192
            case kAudioDevicePropertySafetyOffset: return 32
            default: XCTFail("Unexpected property"); return nil
            }
        }, readStreams: { id, scope in
            XCTAssertEqual(id, 7)
            return [.init(id: 9, virtualRate: 48_000, physicalRate: 96_000,
                          channels: 6, latencyFrames: 24)]
        })
        let snapshot = reader.snapshot(id: 7, name: "Interface", direction: .input,
                                       presentationLatencySeconds: 0.012)
        XCTAssertEqual(snapshot.nominalRate, 48_000)
        XCTAssertEqual(snapshot.actualRate, 47_976)
        XCTAssertEqual(snapshot.bufferFrames, 128)
        XCTAssertEqual(snapshot.deviceLatencyFrames, 96)
        XCTAssertEqual(snapshot.safetyOffsetFrames, 32)
        XCTAssertEqual(snapshot.presentationLatencySeconds, 0.012)
        XCTAssertEqual(snapshot.streams?.first?.physicalRate, 96_000)
        XCTAssertTrue(requests.contains { $0.0 == kAudioDevicePropertyLatency && $0.1 == kAudioObjectPropertyScopeInput })
        XCTAssertTrue(requests.contains { $0.0 == kAudioDevicePropertyActualSampleRate && $0.1 == kAudioObjectPropertyScopeGlobal })
        XCTAssertTrue(snapshot.logDescription.contains("physical rate 96000"))
        XCTAssertTrue(snapshot.logDescription.contains("not added to AV presentation delay"))
        let output = reader.snapshot(id: 7, name: "Interface", direction: .output,
                                     presentationLatencySeconds: 0.02)
        XCTAssertEqual(output.deviceLatencyFrames, 192)
        XCTAssertTrue(requests.contains { $0.0 == kAudioDevicePropertyLatency && $0.1 == kAudioObjectPropertyScopeOutput })
    }

    func testUnknownValuesAreNotSilentlyReplacedWithNominalOrZeroDelay() {
        let reader = DeviceConfigurationReader(readScalar: { _, selector, _ in
            selector == kAudioDevicePropertyNominalSampleRate ? 44_100 : nil
        }, readStreams: { _, _ in nil })
        let snapshot = reader.snapshot(id: 1, name: "Output", direction: .output,
                                       presentationLatencySeconds: nil)
        XCTAssertNil(snapshot.actualRate)
        XCTAssertNil(snapshot.deviceLatencyFrames)
        XCTAssertNil(snapshot.streams)
        XCTAssertTrue(snapshot.logDescription.contains("actual rate unavailable"))
        XCTAssertTrue(snapshot.logDescription.contains("AV presentation delay unavailable"))
        XCTAssertTrue(snapshot.logDescription.contains("streams unavailable"))
    }

    func testInvalidRatesAndDelaysAreRejectedButReportedZeroLatencyIsValid() {
        let reader = DeviceConfigurationReader(readScalar: { _, selector, _ in
            switch selector {
            case kAudioDevicePropertyActualSampleRate: return .nan
            case kAudioDevicePropertyNominalSampleRate: return 0
            case kAudioDevicePropertyBufferFrameSize: return -128
            default: return 0
            }
        }, readStreams: { _, _ in [] })
        let snapshot = reader.snapshot(id: 2, name: "Output", direction: .output,
                                       presentationLatencySeconds: .infinity)
        XCTAssertNil(snapshot.nominalRate)
        XCTAssertNil(snapshot.actualRate)
        XCTAssertNil(snapshot.bufferFrames)
        XCTAssertNil(snapshot.presentationLatencySeconds)
        XCTAssertEqual(snapshot.deviceLatencyFrames, 0)
        XCTAssertEqual(snapshot.safetyOffsetFrames, 0)
        XCTAssertEqual(snapshot.streams?.count, 0)
    }

    func testAdvertisedHardwareCanBeObservedWithoutStartingAudio() throws {
        var count = 0
        for direction in AudioDeviceDirection.allCases {
            for choice in AudioDeviceCatalog.choices(for: direction).dropFirst() {
                let snapshot = DeviceConfigurationReader.hardware.snapshot(id: choice.id, name: choice.name,
                    direction: direction, presentationLatencySeconds: nil)
                XCTAssertEqual(snapshot.id, choice.id)
                if let rate = snapshot.nominalRate { XCTAssertGreaterThan(rate, 0) }
                if let frames = snapshot.bufferFrames { XCTAssertGreaterThan(frames, 0) }
                if ProcessInfo.processInfo.environment["REMSOUND_REPORT_DEVICE_SETUP"] == "1" {
                    print(snapshot.logDescription)
                }
                count += 1
            }
        }
        if count == 0 { throw XCTSkip("No advertised audio device to observe") }
    }
}
