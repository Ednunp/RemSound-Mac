import Foundation
import XCTest

@testable import RemSoundJam

/// The Ogg Opus container: pages any player opens.
final class OggOpusTests: XCTestCase {
    /// A page read back: its header fields, its packets, and whether its checksum is right.
    struct Page {
        var flags: UInt8, granule: Int64, serial: UInt32, sequence: UInt32, packets: [[UInt8]], crcRight: Bool
    }

    static func read(_ bytes: [UInt8]) -> [Page] {
        var pages: [Page] = []
        var at = 0
        while at + 27 <= bytes.count {
            guard Array(bytes[at..<at + 4]) == Array("OggS".utf8) else { break }
            func le(_ from: Int, _ n: Int) -> UInt64 { (0..<n).reduce(0) { $0 | UInt64(bytes[at + from + $1]) << (8 * UInt64($1)) } }
            let segments = Int(bytes[at + 26])
            let lacing = Array(bytes[(at + 27)..<(at + 27 + segments)])
            var packets: [[UInt8]] = [], current: [UInt8] = []
            var body = at + 27 + segments
            for l in lacing {
                current += bytes[body..<(body + Int(l))]
                body += Int(l)
                if l < 255 {
                    packets.append(current)
                    current = []
                }
            }
            var copy = Array(bytes[at..<body])
            let stored = UInt32(le(22, 4))
            copy[22] = 0; copy[23] = 0; copy[24] = 0; copy[25] = 0
            pages.append(Page(flags: bytes[at + 5], granule: Int64(bitPattern: le(6, 8)), serial: UInt32(le(14, 4)),
                              sequence: UInt32(le(18, 4)), packets: packets, crcRight: OggPageWriter.crc(copy) == stored))
            at = body
        }
        return pages
    }

    func testTheChecksumIsOggs() {
        // The CRC-32 Ogg uses (polynomial 0x04C11DB7, unreflected, from 0): the standard check value of this variant,
        // CRC-32/MPEG-2 without its final inversion and starting value, over "123456789" is 0x89A1897F.
        XCTAssertEqual(OggPageWriter.crc(Array("123456789".utf8)), 0x89A1_897F)
        XCTAssertEqual(OggPageWriter.crc([]), 0)
    }

    func testTheHeadersAreOpusHeadAndOpusTagsOnPagesOfTheirOwn() {
        let (_, bytes) = OggOpusWriter.headers(channels: 2, preSkip: 312, serial: 0x1234_5678, comments: ["TITLE=Jam"])
        let pages = Self.read(bytes)
        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue(pages.allSatisfy(\.crcRight))
        XCTAssertEqual(pages[0].flags, 0x02, "the first page begins the stream")
        XCTAssertEqual(pages[1].flags, 0)
        XCTAssertEqual(pages.map(\.sequence), [0, 1])
        XCTAssertEqual(pages.map(\.granule), [0, 0])
        XCTAssertEqual(pages[0].serial, 0x1234_5678)
        let head = pages[0].packets[0]
        XCTAssertEqual(head, Array("OpusHead".utf8) + [1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0],
                       "version 1, two channels, pre-skip 312, 48 kHz, no gain, mapping family 0")
        let tags = pages[1].packets[0]
        XCTAssertEqual(Array(tags.prefix(8)), Array("OpusTags".utf8))
        XCTAssertEqual(Array(tags[8..<12]), [8, 0, 0, 0])
        XCTAssertEqual(Array(tags[12..<20]), Array("RemSound".utf8))
        XCTAssertEqual(Array(tags[20..<24]), [1, 0, 0, 0], "one comment")
        XCTAssertEqual(Array(tags[24..<28]), [9, 0, 0, 0])
        XCTAssertEqual(Array(tags[28...]), Array("TITLE=Jam".utf8))
    }

    func testAudioGoesInPagesOfAboutASecondEachCarryingItsGranuleAndTheLastEndsTheStream() {
        var (writer, bytes) = OggOpusWriter.headers(channels: 2, preSkip: 312, serial: 7)
        // 2.5 s of 20 ms packets (960 samples), of varied sizes, one of exactly 255 bytes and one of 300.
        var sent: [[UInt8]] = []
        for i in 0..<125 {
            let size = i == 10 ? 255 : i == 11 ? 300 : 100 + i % 37
            let packet = [UInt8](repeating: UInt8(i & 0xFF), count: size)
            sent.append(packet)
            bytes += writer.add(packet, samples: 960)
        }
        bytes += writer.finish(trailing: 400)
        let pages = Self.read(bytes)
        XCTAssertTrue(pages.allSatisfy(\.crcRight))
        XCTAssertEqual(pages.map(\.sequence), Array(0..<UInt32(pages.count)), "numbered in order")
        let audio = Array(pages.dropFirst(2))
        XCTAssertEqual(audio.count, 3, "a page a second: 2.5 s is two full pages and a last")
        XCTAssertEqual(audio.flatMap(\.packets), sent, "every packet back, whole, in order - the 255 and 300-byte ones too")
        XCTAssertEqual(audio[0].granule, 312 + 50 * 960, "the granule counts the pre-skip in")
        XCTAssertEqual(audio[1].granule, 312 + 100 * 960)
        XCTAssertEqual(audio[2].granule, 312 + 125 * 960 - 400, "the last page says where the sound really ends")
        XCTAssertEqual(audio[2].flags, 0x04, "and ends the stream")
        XCTAssertEqual(audio[0].flags, 0)
        XCTAssertTrue(writer.finished)
        XCTAssertTrue(writer.add([1, 2, 3], samples: 960).isEmpty, "nothing after the end")
    }

    func testTheRecorderCutsTwentyMillisecondFramesAndSaysWhereTheSoundEnds() {
        var frames: [[Float]] = []
        var (recorder, bytes) = OggOpusRecorder.start(channels: 2, preSkip: 312, serial: 5) { frame in
            frames.append(frame)
            return [UInt8(frames.count & 0xFF), 1, 2]
        }
        // 1.05 s of stereo in blocks of 240 frames, the left channel counting up so the cuts can be checked.
        var n: Float = 0
        for _ in 0..<210 {
            var block: [Float] = []
            for _ in 0..<240 {
                block += [n, -n]
                n += 1
            }
            bytes += recorder.append(stereo: block)
        }
        bytes += recorder.finish()
        XCTAssertEqual(recorder.realFrames, 50_400)
        XCTAssertEqual(frames.count, 53, "52 whole frames, the last 480 filled out with silence - which covers the lookahead")
        XCTAssertTrue(frames.allSatisfy { $0.count == 1920 })
        XCTAssertEqual(frames[1][0], 960, "each frame starts where the last left off")
        XCTAssertEqual(frames[1][1], -960)
        XCTAssertEqual(frames[52][958], 50_399, "the last real sample, left")
        XCTAssertEqual(frames[52][959], -50_399, "and right")
        XCTAssertEqual(frames[52][960], 0, "then silence")
        let pages = Self.read(bytes)
        XCTAssertTrue(pages.allSatisfy(\.crcRight))
        XCTAssertEqual(pages.last?.flags, 0x04)
        XCTAssertEqual(pages.last?.granule, 312 + 50_400, "a player plays exactly the sound given")
        XCTAssertEqual(pages.dropFirst(2).flatMap(\.packets).count, 53)
    }

    func testWhenTheLastFrameIsNearlyFullASilentFrameCarriesTheLookaheadOut() {
        var count = 0
        var (recorder, bytes) = OggOpusRecorder.start(channels: 1, preSkip: 312, serial: 5) { frame in
            count += 1
            return [1]
        }
        bytes += recorder.append(stereo: [Float](repeating: 0.5, count: 2 * 1900))   // 1900 frames: 940 in the second
        bytes += recorder.finish()
        XCTAssertEqual(count, 3, "the second frame ends only 20 samples past the sound, under the 312 held back: one more")
        XCTAssertEqual(Self.read(bytes).last?.granule, 312 + 1900)
        XCTAssertTrue(recorder.finish().isEmpty, "finished once")
    }

    func testMonoIsTheTwoSidesAveragedAndAFrameTheEncoderRefusesIsLeftOut() {
        var got: [[Float]] = []
        var fail = true
        var (recorder, bytes) = OggOpusRecorder.start(channels: 1, preSkip: 0, serial: 5) { frame in
            defer { fail = false }
            if fail { return nil }
            got.append(frame)
            return [7]
        }
        XCTAssertEqual(Array(Self.read(bytes)[0].packets[0][9...9]), [1], "one channel in the OpusHead")
        bytes += recorder.append(stereo: [Float]([0.2, 0.6] + [Float](repeating: 0, count: 2 * 959) + [1, 0] + [Float](repeating: 0, count: 2 * 959)))
        bytes += recorder.finish()
        XCTAssertEqual(recorder.failedFrames, 960)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0][0], 0.5, "the second frame, (1 + 0) / 2")
        XCTAssertEqual(Self.read(bytes).last?.granule, 960, "only the frame that was encoded is in the file")
    }

    func testAPacketExactlyAMultipleOf255EndsWithAZeroLacingValue() {
        var pages = OggPageWriter(serial: 1)
        let page = pages.page([[UInt8](repeating: 9, count: 510)], granule: 0)
        XCTAssertEqual(page[26], 3)
        XCTAssertEqual(Array(page[27..<30]), [255, 255, 0])
    }
}
