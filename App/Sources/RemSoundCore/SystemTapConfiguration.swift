import AudioToolbox
import Foundation

// Captured at setup and read on the session worker. Never queried on an IOProc.
struct SystemTapConfiguration {
    enum Target {
        case allOutputs
        case device(stream: UInt, pair: Int)
        case applications(processCount: Int)
        var description: String {
            switch self {
            case .allOutputs: return "all outputs"
            case .device(let stream, let pair): return "device stream index \(stream), pair within stream \(pair) (zero-based)"
            case .applications(let count): return "\(count) application sound processes"
            }
        }
    }
    let id: UUID
    let target: Target
    let format: AudioStreamBasicDescription

    func descriptions(aggregate: DeviceConfigurationSnapshot, source: DeviceConfigurationSnapshot?) -> [String] {
        let layout = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "non-interleaved" : "interleaved"
        return ["Core Audio tap setup \(id): \(target.description), tap format \(String(format: "%.3f", format.mSampleRate)) Hz, "
            + "channels \(format.mChannelsPerFrame), \(format.mBitsPerChannel) bits/channel, \(layout), "
            + "bytes/frame \(format.mBytesPerFrame), format ID \(String(format: "%08X", format.mFormatID)), "
            + "flags \(String(format: "%08X", format.mFormatFlags)). Tap format is not the underlying device's measured rate; "
            + "not a hardware capture timestamp.",
            "capture aggregate: " + aggregate.logDescription,
            source.map { "captured output: " + $0.logDescription }
                ?? "Tap underlying output device/rate unavailable for a global or application mix."]
    }
}
