import Foundation

/// One packet's capture time, for a report to the server: the stream it went out on, the sequence it went out with,
/// and when its first sample reached the input, in this machine's metronome clock.
public struct CaptureReport: Equatable, Sendable {
    public var stream: UInt16
    public var sequence: UInt32
    public var capturedUs: Int64
    public init(stream: UInt16, sequence: UInt32, capturedUs: Int64) {
        self.stream = stream
        self.sequence = sequence
        self.capturedUs = capturedUs
    }
}

/// When each packet's sound was captured, for the server's metronome - the Mac's copy of the Windows sender lane's
/// capture timeline (live test 2026-09-29, Ed: "see if that code to lock can be made better").
///
/// The server measures this machine by pairing each packet's capture time with when the packet reached it, and keeps the
/// least delay it sees. So a capture time must be the input's, not the moment our code happened to run: a block reaches
/// us late by however long the capture thread (or the send timer) took - never early - and that lateness, kept by the
/// server's "least", would make this machine's beat come late by the worst of it. Instead every reading says when frame
/// 0 of the stream must have been captured; the earliest of the last 2 to 4 seconds is the one that ran on time, and each
/// packet is timed from it by its frame count. Two buckets, so the reading follows the audio card's clock as it drifts
/// against this one; a jump later by more than 20 ms (a capture that restarted or lost sound), or a pause, starts again.
public struct CaptureTimeline {
    public static let sampleRate = 48_000.0
    static let bucketUs: Int64 = 2_000_000
    static let jumpUs: Int64 = 20_000
    private var current = Int64.max, previous = Int64.max, bucketStart: Int64 = 0

    public init() {}

    /// The capture time of the frame `frameIndex` frames into the stream, given one reading of it:
    /// `readingUs` - now, less the input's own delay, less how long ago that frame came in (frames still waiting, say).
    /// Late readings are ignored in favour of the earliest recent one.
    public mutating func captureTime(frameIndex: Int64, readingUs: Int64) -> Int64 {
        let framesUs = Int64((Double(frameIndex) * 1_000_000 / Self.sampleRate).rounded())
        let origin = readingUs - framesUs
        let envelope = min(current, previous)
        if envelope == .max || origin - envelope > Self.jumpUs || readingUs - bucketStart >= 2 * Self.bucketUs {
            current = origin
            previous = origin
            bucketStart = readingUs
        } else {
            if readingUs - bucketStart >= Self.bucketUs {
                previous = current
                current = .max
                bucketStart = readingUs
            }
            current = min(current, origin)
        }
        return min(current, previous) + framesUs
    }
}

/// The newest packets' capture times, kept for the once-a-second report: at most `ServerMetronomeWire.maxReportEntries`.
public struct CaptureReportRing {
    private var entries: [CaptureReport] = []
    public init() {}

    public mutating func note(_ report: CaptureReport) {
        entries.append(report)
        if entries.count > ServerMetronomeWire.maxReportEntries { entries.removeFirst(entries.count - ServerMetronomeWire.maxReportEntries) }
    }

    /// The packets noted since the last call, oldest first; forgotten.
    public mutating func take() -> [CaptureReport] {
        defer { entries = [] }
        return entries
    }
}
