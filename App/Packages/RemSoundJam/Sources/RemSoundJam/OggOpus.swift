import Foundation

// RECORDING TO OGG OPUS: the container (RFC 3533, Ogg; RFC 7845, Opus in Ogg). The Opus packets themselves come from the
// Mac's libopus encoder (AudioSupport); this lays them out as a file any player opens: an OpusHead page, an OpusTags page,
// then the audio in pages of about a second, each with its granule position, the last marked end of stream. Plain
// Swift: its tests run on Windows as on a Mac.

/// Writes an Ogg stream page by page into memory; the caller writes the bytes where it likes, as they come.
public struct OggPageWriter {
    public let serial: UInt32
    private var sequence: UInt32 = 0

    public init(serial: UInt32) { self.serial = serial }

    /// One page: `packets` (each whole, laced), the granule position after its last packet, and its flags.
    /// Returns the page's bytes.
    public mutating func page(_ packets: [[UInt8]], granule: Int64, firstPage: Bool = false, lastPage: Bool = false) -> [UInt8] {
        var lacing: [UInt8] = []
        var body: [UInt8] = []
        for packet in packets {
            var left = packet.count
            while left >= 255 {
                lacing.append(255)
                left -= 255
            }
            lacing.append(UInt8(left))   // a packet a multiple of 255 long ends with a 0
            body += packet
        }
        precondition(lacing.count <= 255, "an Ogg page holds at most 255 lacing values")
        var page: [UInt8] = Array("OggS".utf8)
        page.append(0)                                                 // version
        page.append((firstPage ? 0x02 : 0) | (lastPage ? 0x04 : 0))    // beginning / end of stream
        page += Self.bytes(UInt64(bitPattern: granule))
        page += Self.bytes(serial)
        page += Self.bytes(sequence)
        page += [0, 0, 0, 0]                                           // the checksum, filled in below
        page.append(UInt8(lacing.count))
        page += lacing
        page += body
        let crc = Self.crc(page)
        page[22] = UInt8(crc & 0xFF)
        page[23] = UInt8((crc >> 8) & 0xFF)
        page[24] = UInt8((crc >> 16) & 0xFF)
        page[25] = UInt8(crc >> 24)
        sequence += 1
        return page
    }

    /// Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, starting from 0, nothing XORed at the end.
    public static func crc(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        return crc
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    static func bytes(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    static func bytes(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    static func bytes(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
}

/// An Ogg Opus file, a packet at a time.
public struct OggOpusWriter {
    /// Opus always counts time at 48 kHz in Ogg (RFC 7845).
    public static let granuleRate = 48_000
    /// About a second of audio a page.
    public static let pageSamples = 48_000

    private var pages: OggPageWriter
    private var pending: [[UInt8]] = []
    private var pendingSamples = 0
    /// Samples written so far, the pre-skip counted in (the granule position of the last packet given).
    public private(set) var granule: Int64
    public let preSkip: UInt16
    public private(set) var finished = false

    /// The two header pages, to write first. `preSkip` is the encoder's lookahead in 48 kHz samples (what
    /// OPUS_GET_LOOKAHEAD says; 312 for libopus at 48 kHz); a player drops that many from the start.
    public static func headers(channels: Int, preSkip: UInt16, serial: UInt32, vendor: String = "RemSound",
                               comments: [String] = []) -> (writer: OggOpusWriter, bytes: [UInt8]) {
        var head: [UInt8] = Array("OpusHead".utf8)
        head.append(1)                                       // version
        head.append(UInt8(channels))
        head += OggPageWriter.bytes(preSkip)
        head += OggPageWriter.bytes(UInt32(granuleRate))     // the input's rate, for information
        head += OggPageWriter.bytes(UInt16(0))               // output gain
        head.append(0)                                       // channel mapping family 0: mono or stereo
        var tags: [UInt8] = Array("OpusTags".utf8)
        let vendorBytes = Array(vendor.utf8)
        tags += OggPageWriter.bytes(UInt32(vendorBytes.count))
        tags += vendorBytes
        tags += OggPageWriter.bytes(UInt32(comments.count))
        for c in comments {
            let b = Array(c.utf8)
            tags += OggPageWriter.bytes(UInt32(b.count))
            tags += b
        }
        var writer = OggOpusWriter(serial: serial, preSkip: preSkip)
        let bytes = writer.pages.page([head], granule: 0, firstPage: true) + writer.pages.page([tags], granule: 0)
        return (writer, bytes)
    }

    private init(serial: UInt32, preSkip: UInt16) {
        pages = OggPageWriter(serial: serial)
        self.preSkip = preSkip
        granule = Int64(preSkip)
    }

    /// One encoded Opus packet holding `samples` samples (at 48 kHz). Returns a page's bytes when one is full, else none.
    public mutating func add(_ packet: [UInt8], samples: Int) -> [UInt8] {
        guard !finished else { return [] }
        pending.append(packet)
        pendingSamples += samples
        granule += Int64(samples)
        let lacing = pending.reduce(0) { $0 + $1.count / 255 + 1 }
        guard pendingSamples >= Self.pageSamples || lacing > 200 else { return [] }
        return flush(last: false)
    }

    /// The last page, marked end of stream. `trailing` samples of the last packet are past the end of the sound
    /// (padding the encoder needed): the granule position says where the sound really stops.
    public mutating func finish(trailing: Int = 0) -> [UInt8] {
        guard !finished else { return [] }
        granule -= Int64(trailing)
        let bytes = flush(last: true)
        finished = true
        return bytes
    }

    private mutating func flush(last: Bool) -> [UInt8] {
        let bytes = pages.page(pending, granule: granule, lastPage: last)
        pending = []
        pendingSamples = 0
        return bytes
    }
}

/// A recording to Ogg Opus (Windows' OggOpusFormatWriter: 20 ms frames), fed interleaved stereo at 48 kHz in blocks of
/// any size. Mono is (left + right) / 2, as Windows. Each 20 ms frame goes to `encode` (the Mac's libopus; anything in
/// tests), its packet into a page. At the end the last frame is filled out with silence - and a frame more if the
/// encoder's lookahead would otherwise keep the last of the sound back - and the last page says where the sound ends.
public struct OggOpusRecorder {
    public static let frameSamples = 960
    public let channels: Int
    public let preSkip: Int
    private var writer: OggOpusWriter
    private var pending: [Float] = []
    private let encode: ([Float]) -> [UInt8]?
    /// Frames of real sound given, and frames sent to the encoder (sound and the silence after it).
    public private(set) var realFrames = 0, encodedFrames = 0
    /// Frames the encoder could not encode (left out of the file).
    public private(set) var failedFrames = 0

    /// The recorder and the header pages to write first.
    public static func start(channels: Int, preSkip: Int, serial: UInt32, vendor: String = "RemSound",
                             encode: @escaping ([Float]) -> [UInt8]?) -> (recorder: OggOpusRecorder, bytes: [UInt8]) {
        let (writer, bytes) = OggOpusWriter.headers(channels: channels, preSkip: UInt16(max(0, min(65535, preSkip))),
                                                    serial: serial, vendor: vendor)
        return (OggOpusRecorder(channels: channels, preSkip: preSkip, writer: writer, encode: encode), bytes)
    }

    private init(channels: Int, preSkip: Int, writer: OggOpusWriter, encode: @escaping ([Float]) -> [UInt8]?) {
        self.channels = channels
        self.preSkip = preSkip
        self.writer = writer
        self.encode = encode
    }

    /// Interleaved stereo; returns any finished pages.
    public mutating func append(stereo samples: [Float]) -> [UInt8] {
        let frames = samples.count / 2
        realFrames += frames
        if channels == 1 {
            for i in 0..<frames { pending.append((samples[2 * i] + samples[2 * i + 1]) * 0.5) }
        } else {
            pending += samples.prefix(frames * 2)
        }
        var bytes: [UInt8] = []
        let wide = Self.frameSamples * channels
        while pending.count >= wide {
            bytes += encodeFrame(Array(pending.prefix(wide)))
            pending.removeFirst(wide)
        }
        return bytes
    }

    /// The last pages, the stream ended. Nothing more is taken after this.
    public mutating func finish() -> [UInt8] {
        guard !writer.finished else { return [] }
        var bytes: [UInt8] = []
        let wide = Self.frameSamples * channels
        if !pending.isEmpty {
            bytes += encodeFrame(pending + [Float](repeating: 0, count: wide - pending.count))
            pending = []
        }
        // The encoder holds its lookahead back: what is sent after the sound must cover it (a frame the encoder
        // refused is not in the file, so it is not counted as sound).
        let sound = max(0, realFrames - failedFrames)
        var tries = 0
        while encodedFrames - sound < preSkip && tries < 4 {
            tries += 1
            bytes += encodeFrame([Float](repeating: 0, count: wide))
        }
        return bytes + writer.finish(trailing: max(0, encodedFrames - sound))
    }

    private mutating func encodeFrame(_ frame: [Float]) -> [UInt8] {
        guard let packet = encode(frame), !packet.isEmpty else {
            failedFrames += Self.frameSamples
            return []
        }
        encodedFrames += Self.frameSamples
        return writer.add(packet, samples: Self.frameSamples)
    }
}
