import AudioToolbox
import CoreAudio
import XCTest
@testable import RemSoundCore

final class SystemTapConfigurationTests: XCTestCase {
    private func device(_ id: AudioDeviceID, _ direction: AudioDeviceDirection) -> DeviceConfigurationSnapshot {
        .init(id: id, name: "Card", direction: direction, nominalRate: 96_000, actualRate: 95_990,
              bufferFrames: 128, deviceLatencyFrames: 20, safetyOffsetFrames: 30,
              presentationLatencySeconds: nil, streams: [])
    }

    func testTapFormatAndChosenStreamAreKeptSeparateFromSourceAndAggregateFormats() {
        let format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 6, mBitsPerChannel: 32, mReserved: 0)
        let setup = SystemTapConfiguration(id: UUID(), target: .device(stream: 2, pair: 1), format: format)
        let lines = setup.descriptions(aggregate: device(7, .input), source: device(9, .output))
        XCTAssertTrue(lines[0].contains("tap format 48000"))
        XCTAssertTrue(lines[0].contains("channels 6"))
        XCTAssertTrue(lines[0].contains("non-interleaved"))
        XCTAssertTrue(lines[0].contains("stream index 2, pair within stream 1"))
        XCTAssertTrue(lines[1].contains("capture aggregate: Core Audio setup input"))
        XCTAssertTrue(lines[2].contains("captured output: Core Audio setup output"))
        XCTAssertTrue(lines[2].contains("actual rate 95990"))
        XCTAssertTrue(lines[0].contains("not a hardware capture timestamp"))
    }

    func testGlobalAndApplicationMixesDoNotInventOneUnderlyingDevice() {
        var format = AudioStreamBasicDescription()
        format.mSampleRate = 44_100
        format.mChannelsPerFrame = 2
        let global = SystemTapConfiguration(id: UUID(), target: .allOutputs, format: format)
        let apps = SystemTapConfiguration(id: UUID(), target: .applications(processCount: 3), format: format)
        let globalLines = global.descriptions(aggregate: device(4, .input), source: nil)
        let appLines = apps.descriptions(aggregate: device(4, .input), source: nil)
        XCTAssertTrue(globalLines[0].contains("all outputs"))
        XCTAssertTrue(globalLines[0].contains("tap format 44100"))
        XCTAssertTrue(appLines[0].contains("3 application sound processes"))
        XCTAssertTrue(globalLines.last!.contains("underlying output device/rate unavailable"))
        XCTAssertTrue(appLines.last!.contains("underlying output device/rate unavailable"))
    }
}
