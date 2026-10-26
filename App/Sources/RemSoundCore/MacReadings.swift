import Foundation
import RemSoundJam

/// The columns of the Mac's readings file (Windows 6.2.3, its issue 35): what the once-a-second log lines used to say,
/// as named columns that open in a spreadsheet. Each belongs to what it measures, and is written only while that is in
/// use (Ed: readings "only get logged when they get turned on") - not sending, no stream, no plugin, no server leave
/// their cells empty. The Mac's own deep-dive observations (callback budgets, clock and timestamp observations, a
/// plugin's host callbacks, each journey's latency parts) go in `observations`, in second rows only.
enum MacReadings {
    // What a reading belongs to. "" is always in use (the program itself).
    static let receiving = "receiving"
    static let sending = "sending"
    static let jamulusStyle = "Jamulus-style"
    static let audio = "audio"
    static let plugin = "plugin"
    static let server = "server"
    static let stream = "stream"
    static let card = "output card"
    static let peer = "peer"

    private static func n(_ name: String, _ agg: ReadingAgg, _ group: String = "") -> ReadingColumn {
        ReadingColumn(name, agg, group: group)
    }
    private static func t(_ name: String, _ group: String = "", agg: ReadingAgg = .last) -> ReadingColumn {
        ReadingColumn(name, agg, group: group, text: true)
    }

    static let schema = ReadingsSchema([
        // The Mac as a whole.
        n("sending", .last), n("sendingTo", .last), n("connectedPeers", .last), n("sendFailuresTotal", .last),
        n("canPlayJamulusStyle", .last),
        // Receiving: totals since the session started (the receive totals line).
        n("audibleGapsTotal", .last, receiving), n("concealedTotal", .last, receiving),
        n("lateOrDoubledDroppedTotal", .last, receiving), n("gapsNotRepairedTotal", .last, receiving),
        n("malformedPacketsTotal", .last, receiving), n("refusedAudioTotal", .last, receiving),
        n("notAllowedTotal", .last, receiving), n("rejectedPCMTotal", .last, receiving),
        n("discardedPCMTotal", .last, receiving), n("reorderWaitsTotal", .last, receiving),
        // Sending: the send interval lines, summed over the streams sent.
        n("sentPackets", .sum, sending), n("sentFrames", .sum, sending), n("sendCopies", .sum, sending),
        n("sendFailures", .sum, sending), n("emitGapMaxMs", .max, sending), n("emitGapP95Ms", .max, sending),
        n("jamulusStyleTo", .last, jamulusStyle), n("jamulusStyleFrames", .sum, jamulusStyle),
        // Sound cards: the delays line.
        n("inputLatencyMs", .last, audio), n("outputLatencyMs", .last, audio), n("playbackQueuedMs", .mean, audio),
        n("playbackQueuedMaxMs", .max, audio), n("mixFrames", .last, audio),
        n("pluginInstances", .last, plugin),
        t("serverStatus", server), t("metronome", server),
        t("observations", agg: .secondsOnly),
        // An incoming stream ("Ed/7"): only in its own row.
        t("codec", stream), n("frames", .last, stream), n("packets", .sum, stream), n("arrivalGapMaxMs", .max, stream),
        n("arrivalGapP95Ms", .max, stream), n("queueMinMs", .min, stream), n("queueMeanMs", .mean, stream),
        n("queueMaxMs", .max, stream), n("queuedMs", .mean, stream), n("targetMs", .last, stream),
        n("concealed", .sum, stream), n("underruns", .sum, stream), n("trims", .sum, stream),
        n("trimmedFrames", .sum, stream), n("clockPpm", .last, stream),
        // An output card ("card 1"): keeping it in time with the mix.
        n("cardClockPpm", .last, card), n("cushionMs", .last, card), n("laidMs", .last, card), n("cutMs", .last, card),
        n("ranDry", .last, card),
        // A ticked peer ("Ed", output "peer"): its ping and total latency.
        n("pingMs", .mean, peer), n("pingMaxMs", .max, peer), n("totalLatencyMs", .mean, peer), t("peerStatus", peer),
    ])
}
