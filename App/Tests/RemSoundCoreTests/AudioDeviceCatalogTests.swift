import XCTest
import AVFoundation
import CoreAudio
@testable import RemSoundCore

final class AudioDeviceCatalogTests: XCTestCase {
    func testChoicesHaveDefaultAndStableUniqueIDs() throws {
        for direction in [AudioDeviceDirection.input, .output] {
            let choices = AudioDeviceCatalog.choices(for: direction)
            XCTAssertEqual(choices.first?.uid, "")
            XCTAssertFalse(choices.first?.name.isEmpty ?? true)
            XCTAssertEqual(Set(choices.map(\.uid)).count, choices.count)
            for choice in choices.dropFirst() {
                XCTAssertFalse(choice.uid.isEmpty)
                XCTAssertFalse(choice.name.isEmpty)
                XCTAssertEqual(try AudioDeviceCatalog.resolve(choice.uid, for: direction), choice.id)
            }
        }
    }

    func testMissingDeviceIsRejectedRatherThanSilentlyUsingDefault() {
        XCTAssertThrowsError(try AudioDeviceCatalog.resolve("missing-device-test", for: .input))
        XCTAssertThrowsError(try AudioDeviceCatalog.resolve("missing-device-test", for: .output))
    }
    func testRouteIdentityDistinguishesDefaultAndMissingNamedDevice() {
        let defaultRoute = AudioDeviceCatalog.activeIdentity("", for: .input)
        let missing = AudioDeviceCatalog.activeIdentity("missing-device-test", for: .input)
        XCTAssertTrue(defaultRoute.hasPrefix("default:"))
        XCTAssertEqual(missing, "missing:missing-device-test")
        if let choice = AudioDeviceCatalog.choices(for: .input).dropFirst().first {
            XCTAssertEqual(AudioDeviceCatalog.activeIdentity(choice.uid, for: .input),
                "\(choice.uid):\(choice.id)")
        }
    }

    func testSystemCaptureCanTargetOneOutputInsteadOfAllOutputs() {
        let all = SystemAudioCapture.tapDescription(deviceUID: "", excluded: [])
        let selected = SystemAudioCapture.tapDescription(
            deviceUID: "test-output-uid", excluded: [])
        XCTAssertNil(all.deviceUID)
        XCTAssertEqual(selected.deviceUID, "test-output-uid")
        XCTAssertEqual(selected.stream, 0)
    }
    func testSystemCapturePairRoutesAcrossStreams() {
        XCTAssertEqual(AudioDeviceCatalog.captureRoutes(streamChannelCounts: [4, 2, 2]), [
            SystemCaptureChannelRoute(pair: 0, stream: 0, pairInStream: 0),
            SystemCaptureChannelRoute(pair: 1, stream: 0, pairInStream: 1),
            SystemCaptureChannelRoute(pair: 2, stream: 1, pairInStream: 0),
            SystemCaptureChannelRoute(pair: 3, stream: 2, pairInStream: 0),
        ])
        XCTAssertTrue(AudioDeviceCatalog.captureRoutes(
            streamChannelCounts: [1, 3]).isEmpty)
    }
    func testConnectedOutputCaptureRoutesAreWithinTheirStreams() {
        for choice in AudioDeviceCatalog.choices(for: .output).dropFirst() {
            let routes = AudioDeviceCatalog.systemCaptureRoutes(choice.uid)
            let pairs = AudioDeviceCatalog.outputChannelPairCount(choice.uid)
            if pairs > 1 {
                XCTAssertEqual(routes.count, pairs, choice.name)
            }
            XCTAssertEqual(routes.map(\.pair), Array(0..<routes.count), choice.name)
        }
    }

    func testSelectedInputAndOutputStartOnRealHardware() throws {
        guard ProcessInfo.processInfo.environment["REMSOUND_TEST_AUDIO_DEVICES"] == "1" else {
            throw XCTSkip("Run explicitly on a Mac with available audio hardware")
        }
        guard let input = AudioDeviceCatalog.choices(for: .input).dropFirst().first,
            let output = AudioDeviceCatalog.choices(for: .output).dropFirst().first else {
            throw XCTSkip("No selectable input and output devices")
        }
        let audio = DeviceAudio()
        defer { audio.stop() }
        try audio.start(send: true, receive: true,
            inputDeviceUID: input.uid, outputDeviceUID: output.uid)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertGreaterThan(audio.capture.available, 0,
            "The selected input must deliver real audio callbacks")
    }
}
