import XCTest
import AudioSupport
import RemSoundJam
@testable import RemSoundCore

// Independent libopus oracle: the test bypasses the production wrapper's hard-coded decode mode.
@_silgen_name("opus_decode_float")
private func fixtureOpusDecode(_ decoder: UnsafeMutableRawPointer, _ bytes: UnsafePointer<UInt8>?,
    _ length: Int32, _ samples: UnsafeMutablePointer<Float>, _ frames: Int32, _ fec: Int32) -> Int32

final class OpusLossTests: XCTestCase {
    private var oldClock = true
    override func setUp() { oldClock = ClockKeeping.on; ClockKeeping.on = false }
    override func tearDown() { ClockKeeping.on = oldClock }

    private func send(_ decoder: StreamDecoder, _ key: Credentials, _ plain: Data,
        _ sequence: UInt32, tampered: Bool = false) throws -> Bool {
        var sealed = try key.seal(plain)
        if tampered { sealed[sealed.count - 1] ^= 1 }
        let packet = try XCTUnwrap(Wire.parse(Wire.packet(.audio, sequence: sequence, payload: sealed)))
        return decoder.accept(packet, credentials: key)
    }

    func testStandardMultipleLossDoesNotInventPLCAndCountsOneGap() throws {
        let key = try Credentials(password: "isolated ordinary Opus loss")
        let encoder = try XCTUnwrap(OpusSender(bitrate: 128_000))
        let plain = try XCTUnwrap(encoder.encode([Float](repeating: 0.125, count: 960)))
        for missing in [2, 3, 4, 5, 8, 999_999, 1_000_000] {
            let decoder = StreamDecoder(.opus(key.fingerprint, frames: 480), jitterMs: 2, smoothness: 10)
            decoder.receiveTotals = ReceiveTotals()
            XCTAssertTrue(try send(decoder, key, plain, 1))
            XCTAssertTrue(try send(decoder, key, plain, UInt32(missing + 2)))
            XCTAssertEqual(decoder.queuedFrames, 960, "Missing \(missing)")
            XCTAssertEqual(decoder.receiveTotals?.concealed, 0)
            XCTAssertEqual(decoder.receiveTotals?.gapsNotRepaired, missing < 1_000_000 ? 1 : 0)
        }
    }

    func testCustomRepairsEveryGapThroughEightAndLeavesNineUnfilled() throws {
        let key = try Credentials(password: "isolated custom Opus loss bound")
        let encoder = try XCTUnwrap(OpusCustomSender(frames: 64))
        let plain = try XCTUnwrap(encoder.encode([Float](repeating: 0.125, count: 128)))
        for missing in 1...9 {
            let decoder = StreamDecoder(.opusCustom(key.fingerprint, frames: 64), jitterMs: 2, smoothness: 10)
            decoder.receiveTotals = ReceiveTotals()
            XCTAssertTrue(try send(decoder, key, plain, 1))
            XCTAssertTrue(try send(decoder, key, plain, UInt32(missing + 2)))
            XCTAssertEqual(decoder.queuedFrames, (missing <= 8 ? missing + 2 : 2) * 64)
            XCTAssertEqual(decoder.receiveTotals?.concealed, missing <= 8 ? missing : 0)
            XCTAssertEqual(decoder.receiveTotals?.gapsNotRepaired, missing <= 8 ? 0 : 1)
        }
    }

    private func fecPackets() throws -> [Data] {
        struct Fixture: Decodable { let frames: Int; let channels: Int; let packets: [String] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "opus-fec-voice", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.frames, 960); XCTAssertEqual(fixture.channels, 1)
        return try fixture.packets.map { hex in
            let chars = Array(hex)
            return Data(try stride(from: 0, to: chars.count, by: 2).map {
                try XCTUnwrap(UInt8(String(chars[$0...$0 + 1]), radix: 16))
            })
        }
    }

    private func oracle(_ decoder: UnsafeMutableRawPointer, _ packet: Data?, fec: Bool = false) throws -> [Float] {
        var samples = [Float](repeating: 0, count: 960)
        let frames: Int32
        if let packet {
            frames = packet.withUnsafeBytes {
                fixtureOpusDecode(decoder, $0.bindMemory(to: UInt8.self).baseAddress,
                    Int32(packet.count), &samples, 960, fec ? 1 : 0)
            }
        } else { frames = fixtureOpusDecode(decoder, nil, 0, &samples, 960, 0) }
        XCTAssertEqual(frames, 960)
        return samples
    }

    func testSingleLossUsesArrivingFECBeforeNormalDecodeAndNormalizesMono() throws {
        let packets = try fecPackets()
        let key = try Credentials(password: "isolated genuine SILK FEC vector")
        var format = StreamFormat.opus(key.fingerprint, frames: 960)
        format.channels = 1
        let decoder = StreamDecoder(format, jitterMs: 2, smoothness: 10)
        decoder.receiveTotals = ReceiveTotals()
        let expectedDecoder = try XCTUnwrap(rs_opus_decoder(1))
        let plcDecoder = try XCTUnwrap(rs_opus_decoder(1))
        defer { rs_opus_destroy(expectedDecoder); rs_opus_destroy(plcDecoder) }
        for index in 0..<10 {
            XCTAssertTrue(try send(decoder, key, packets[index], UInt32(index + 1)))
            _ = decoder.read(960)
            _ = try oracle(expectedDecoder, packets[index]); _ = try oracle(plcDecoder, packets[index])
        }
        let fec = try oracle(expectedDecoder, packets[11], fec: true)
        let plc = try oracle(plcDecoder, nil)
        XCTAssertGreaterThan(zip(fec, plc).map { abs($0 - $1) }.max() ?? 0, 0.01,
            "The synthetic vector must contain genuine FEC, rather than falling back to PLC")
        let arriving = try oracle(expectedDecoder, packets[11])
        XCTAssertTrue(try send(decoder, key, packets[11], 12))
        XCTAssertEqual(decoder.queuedFrames, 1920)
        let actual = decoder.read(1920)
        let expected = (fec + arriving).flatMap { [$0, $0] }
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertLessThan(zip(actual.dropFirst(96), expected.dropFirst(96)).map { abs($0 - $1) }.max() ?? 1, 0.0001)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 1)
        XCTAssertEqual(decoder.receiveTotals?.gapsNotRepaired, 0)
    }

    func testUnauthenticatedPacketCannotAdvanceGapRepairReference() throws {
        let key = try Credentials(password: "isolated custom authenticated gaps")
        let encoder = try XCTUnwrap(OpusCustomSender(frames: 64))
        let plain = try XCTUnwrap(encoder.encode([Float](repeating: 0.125, count: 128)))
        let decoder = StreamDecoder(.opusCustom(key.fingerprint, frames: 64), jitterMs: 2, smoothness: 10)
        decoder.receiveTotals = ReceiveTotals()
        XCTAssertTrue(try send(decoder, key, plain, 1))
        XCTAssertFalse(try send(decoder, key, plain, 6, tampered: true))
        XCTAssertTrue(try send(decoder, key, plain, 7))
        XCTAssertEqual(decoder.queuedFrames, 448)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 5)
    }

    func testAuthenticatedDecodeFailureDoesNotRepairTheSameGapAgain() throws {
        let key = try Credentials(password: "isolated failed ordinary decode")
        let encoder = try XCTUnwrap(OpusSender(bitrate: 128_000))
        let plain = try XCTUnwrap(encoder.encode([Float](repeating: 0.125, count: 960)))
        let decoder = StreamDecoder(.opus(key.fingerprint, frames: 480), jitterMs: 2, smoothness: 10)
        decoder.receiveTotals = ReceiveTotals()
        XCTAssertTrue(try send(decoder, key, plain, 1))
        XCTAssertFalse(try send(decoder, key, Data([0xff]), 3))
        XCTAssertTrue(try send(decoder, key, plain, 4))
        XCTAssertEqual(decoder.queuedFrames, 960)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 0)
        XCTAssertEqual(decoder.receiveTotals?.gapsNotRepaired, 0)
    }

    func testSingleLossWrapAndMinimumFECFrameSize() throws {
        let key = try Credentials(password: "isolated wrapped minimum FEC")
        let encoder = try XCTUnwrap(OpusSender(bitrate: 128_000))
        let plain = try XCTUnwrap(encoder.encode([Float](repeating: 0.125, count: 240)))
        let decoder = StreamDecoder(.opus(key.fingerprint, frames: 64), jitterMs: 2, smoothness: 10)
        decoder.receiveTotals = ReceiveTotals()
        XCTAssertTrue(try send(decoder, key, plain, UInt32.max - 1))
        XCTAssertTrue(try send(decoder, key, plain, 0))
        XCTAssertEqual(decoder.queuedFrames, 360)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 1)
    }

    func testCustomDecodeFailureDoesNotRepeatAlreadyQueuedPLC() throws {
        let key = try Credentials(password: "isolated custom failed decode repair")
        let encoder = try XCTUnwrap(OpusCustomSender(frames: 64))
        let plain = try XCTUnwrap(encoder.encode([Float](repeating: 0.125, count: 128)))
        let decoder = StreamDecoder(.opusCustom(key.fingerprint, frames: 64), jitterMs: 2, smoothness: 10)
        decoder.receiveTotals = ReceiveTotals()
        XCTAssertTrue(try send(decoder, key, plain, 1))
        XCTAssertFalse(try send(decoder, key, Data([0xff]), 3))
        XCTAssertEqual(decoder.queuedFrames, 128, "The one loss was filled before the failed arrival")
        XCTAssertTrue(try send(decoder, key, plain, 4))
        XCTAssertEqual(decoder.queuedFrames, 192)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 1)
    }

    func testCustom128RepairsEightBeforeArrivalAndRestartHasNoRepair() throws {
        let key = try Credentials(password: "isolated custom128 restart")
        let encoder = try XCTUnwrap(OpusCustomSender(frames: 128))
        let plain = try XCTUnwrap(encoder.encode([Float](repeating: 0.125, count: 256)))
        let decoder = StreamDecoder(.opusCustom(key.fingerprint, frames: 128), jitterMs: 2, smoothness: 10)
        decoder.receiveTotals = ReceiveTotals()
        XCTAssertTrue(try send(decoder, key, plain, 2001))
        XCTAssertTrue(try send(decoder, key, plain, 2010))
        XCTAssertEqual(decoder.queuedFrames, 1280)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 8)
        let reference = try XCTUnwrap(rs_opus_custom_decoder(128))
        defer { rs_opus_custom_decoder_destroy(reference) }
        var expected = [Float]()
        for index in 0..<10 {
            var samples = [Float](repeating: 0, count: 256)
            let frames = index == 0 || index == 9 ? plain.withUnsafeBytes {
                rs_opus_custom_decode(reference, $0.bindMemory(to: UInt8.self).baseAddress,
                    Int32(plain.count), &samples)
            } : rs_opus_custom_decode(reference, nil, 0, &samples)
            XCTAssertEqual(frames, 128)
            expected.append(contentsOf: samples)
        }
        let actual = decoder.read(1280)
        XCTAssertLessThan(zip(actual.dropFirst(96), expected.dropFirst(96)).map { abs($0 - $1) }.max() ?? 1, 0.0001,
            "All eight PLC frames must precede the arriving frame")
        XCTAssertTrue(try send(decoder, key, plain, 1))
        XCTAssertEqual(decoder.queuedFrames, 128)
        XCTAssertEqual(decoder.receiveTotals?.concealed, 8)
    }
}
