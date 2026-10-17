import Foundation

extension DeviceConfigurationSnapshot {
    struct DelayEstimate {
        let hardwareSeconds: Double
        let ioStagingSeconds: Double
        let bufferSeconds: Double
    }
    // Only combine frame components when their reported units agree. This is a
    // setup estimate across advertised streams, never a correction to a timestamp.
    var delayEstimate: DelayEstimate? {
        guard let rate = nominalRate, rate.isFinite, rate > 0,
              let buffer = bufferFrames, buffer.isFinite, buffer > 0,
              let device = deviceLatencyFrames, device.isFinite, device >= 0,
              let safety = safetyOffsetFrames, safety.isFinite, safety >= 0,
              let streams, !streams.isEmpty else { return nil }
        var worstStream: Double = 0
        for stream in streams {
            guard stream.virtualRate == rate, stream.physicalRate == rate,
                  let latency = stream.latencyFrames, latency.isFinite, latency >= 0 else { return nil }
            worstStream = max(worstStream, latency)
        }
        let hardware = (device + worstStream) / rate
        let io = (device + worstStream + safety + buffer) / rate
        guard hardware.isFinite, io.isFinite else { return nil }
        return .init(hardwareSeconds: hardware, ioStagingSeconds: io, bufferSeconds: buffer / rate)
    }
}

struct AudioDelayEstimates {
    enum Source { case selectedInputs, systemOrApplications, dawBridge, unknown }
    struct Comparison {
        let originalTotalMs: Double
        let ioComponentTotalMs: Double
        let inputIOMs: Double
        let includedInputMs: Double
        let inputBufferAlreadyIncludedMs: Double
        let worstOutputIOMs: Double
        var logDescription: String {
            "IO component comparison \(String(format: "%.3f", ioComponentTotalMs)) ms; "
                + "original estimate \(String(format: "%.3f", originalTotalMs)) ms; "
                + "input IO estimate \(String(format: "%.3f", inputIOMs)) ms replaces already included "
                + "\(String(format: "%.3f", includedInputMs)) ms; worst output IO estimate "
                + "\(String(format: "%.3f", worstOutputIOMs)) ms replaces the first AV output figure. "
                + "Established input-buffer overlap \(String(format: "%.3f", inputBufferAlreadyIncludedMs)) ms is removed once. "
                + "Cached setup components at nominal rates across started devices and all advertised streams; "
                + "not an acoustic measurement, exact lane delay or current hardware-timestamp observation. "
                + "Does not change capture timestamps, metronome timing or playback."
        }
    }
    let inputs: [DeviceConfigurationSnapshot]
    let outputs: [DeviceConfigurationSnapshot]
    let expectedInputDevices: Int
    let expectedOutputDevices: Int

    static let empty = AudioDelayEstimates(inputs: [], outputs: [], expectedInputDevices: 0, expectedOutputDevices: 0)
    func compare(source: Source, captureToReturnMs: Double, includedInputMs: Double,
                 receiveQueueMs: Double, outputQueueMs: Double, originalOutputMs: Double,
                 inputBufferAlreadyIncludedMs: Double? = nil) -> Comparison? {
        // The worker origin subtracts queued frames. Do not assume whether that
        // already includes a hardware IO buffer; its overlap must be established.
        guard source == .selectedInputs, expectedInputDevices > 0, expectedOutputDevices > 0,
              let inputBufferAlreadyIncludedMs = inputBufferAlreadyIncludedMs,
              inputs.count == expectedInputDevices, outputs.count == expectedOutputDevices,
              inputs.allSatisfy({ $0.direction == .input }), outputs.allSatisfy({ $0.direction == .output }),
              [captureToReturnMs, includedInputMs, receiveQueueMs, outputQueueMs, originalOutputMs, inputBufferAlreadyIncludedMs]
                .allSatisfy({ $0.isFinite && $0 >= 0 }),
              captureToReturnMs >= includedInputMs + inputBufferAlreadyIncludedMs else { return nil }
        let inputDelays = inputs.compactMap(\.delayEstimate)
        let outputDelays = outputs.compactMap(\.delayEstimate)
        guard inputDelays.count == inputs.count, outputDelays.count == outputs.count,
              let input = inputDelays.map(\.ioStagingSeconds).max(),
              let output = outputDelays.map(\.ioStagingSeconds).max(),
              let buffer = inputDelays.map(\.bufferSeconds).max(), inputBufferAlreadyIncludedMs <= buffer * 1000 else { return nil }
        let original = captureToReturnMs + receiveQueueMs + outputQueueMs + originalOutputMs
        let comparison = captureToReturnMs - includedInputMs - inputBufferAlreadyIncludedMs + input * 1000
            + receiveQueueMs + outputQueueMs + output * 1000
        guard original.isFinite, comparison.isFinite else { return nil }
        return .init(originalTotalMs: original, ioComponentTotalMs: comparison, inputIOMs: input * 1000,
                     includedInputMs: includedInputMs, inputBufferAlreadyIncludedMs: inputBufferAlreadyIncludedMs,
                     worstOutputIOMs: output * 1000)
    }
}
