import Foundation
import RemSoundJam

// One admitted receive stream and one actual output. Components stay paired;
// a slow queue on one stream cannot be combined with another stream's short packet.
struct PeerLatencyReport {
    static let maximumReportedJourneys=64
    let captureMs:Double?
    let packetMs:Double
    let queuedMs:Double
    let rttMs:Double?
    let outputMs:Double?
    init(format:StreamFormat,queuedFrames:Int,rttMs:Double?,outputMs:Double?) {
        captureMs=Self.positive(format.captureLatencyMs)
        packetMs=Double(format.frames)*1000/Double(Wire.sampleRate)
        queuedMs=Double(max(0,queuedFrames))*1000/Double(Wire.sampleRate)
        self.rttMs=Self.nonnegative(rttMs)
        self.outputMs=Self.nonnegative(outputMs)
    }
    private static func positive(_ value:Double) -> Double? {
        value.isFinite && value>0 ? value : nil
    }
    private static func nonnegative(_ value:Double?) -> Double? {
        guard let value,value.isFinite,value>=0 else { return nil };return value
    }
    var knownSubtotalMs:Double {
        JamLogLines.totalLatencyMs(captureMs:captureMs ?? 0,packetMs:packetMs,
            rttMs:rttMs ?? 0,bufferMs:queuedMs,outputMs:outputMs ?? 0)
    }
    var totalMs:Double? {
        guard captureMs != nil,rttMs != nil,outputMs != nil,knownSubtotalMs.isFinite else { return nil }
        return knownSubtotalMs
    }
    static func maximumComplete(_ reports:[Self]) -> Double? {
        guard !reports.isEmpty,reports.allSatisfy({ $0.totalMs != nil }) else { return nil }
        return reports.compactMap(\.totalMs).max()
    }
    var logDescription:String {
        func value(_ v:Double?,unknown:String) -> String { v.map { String(format:"%.3f ms",$0) } ?? unknown }
        return "capture component \(value(captureMs,unknown:"not stated")), packet \(value(packetMs,unknown:"not measured")), "
            + "queued \(value(queuedMs,unknown:"not measured")), round trip \(value(rttMs,unknown:"not measured")), "
            + "output presentation \(value(outputMs,unknown:"not measured")); known-stage subtotal \(String(format:"%.3f",knownSubtotalMs)) ms; "
            + "complete sum \(value(totalMs,unknown:"unavailable")); reported components, not an acoustic measurement."
    }
}

extension PeerLatencyReport {
    struct Input {
        let stream:String
        let format:StreamFormat
        let queuedFrames:Int
    }
    struct Journey {
        let stream:String
        let lane:StreamFormat.Lane
        let output:Int
        let report:PeerLatencyReport
    }
    struct Summary {
        private static let roundingMilliseconds=5
        let journeys:[Journey]
        let outputCount:Int
        let hasMeasuredOutputs:Bool
        let truncated:Bool
        let rttMs:Double?
        let heartbeat: HeartbeatTiming.Health?
        init(inputs:[Input],outputs:[Double?],rttMs:Double?,heartbeat:HeartbeatTiming.Health?=nil) {
            let values=outputs.isEmpty ? [Double?.none] : outputs
            outputCount=values.count;hasMeasuredOutputs = !outputs.isEmpty;self.rttMs=rttMs;self.heartbeat=heartbeat
            var result:[Journey]=[],omitted=false
            for input in inputs {
                for (index,output) in values.enumerated() {
                    guard result.count<PeerLatencyReport.maximumReportedJourneys else { omitted=true;break }
                    result.append(.init(stream:input.stream,lane:input.format.lane,output:index,
                        report:.init(format:input.format,queuedFrames:input.queuedFrames,rttMs:rttMs,outputMs:output)))
                }
                if omitted { break }
            }
            journeys=result;truncated=omitted
        }
        private static func rounded(_ milliseconds:Double?) -> Int? {
            guard let milliseconds,milliseconds.isFinite,milliseconds>=0 else { return nil }
            let units=(milliseconds/Double(roundingMilliseconds)).rounded()
            guard units<Double(Int.max/roundingMilliseconds) else { return nil }
            return Int(units)*roundingMilliseconds
        }
        var maximumCompleteMs:Double? {
            truncated ? nil : PeerLatencyReport.maximumComplete(journeys.map(\.report))
        }
        var status:String {
            let ping=heartbeat?.status ?? (Self.rounded(rttMs).map { "ping \($0) ms" } ?? "ping unknown")
            guard !journeys.isEmpty else { return ping }
            guard !truncated else { return ping+", total latency unavailable (additional journeys omitted)" }
            var parts=[ping]
            for output in 0..<outputCount {
                let reports=journeys.filter { $0.output==output }.map(\.report)
                let suffix=outputCount>1 ? " on Core Audio output \(output+1)" : ""
                if let total=Self.rounded(PeerLatencyReport.maximumComplete(reports)) {
                    parts.append("total latency about \(total) ms"+suffix)
                } else {
                    var missing:[String]=[]
                    if reports.contains(where:{ $0.captureMs==nil }) { missing.append("capture not stated") }
                    if reports.contains(where:{ $0.rttMs==nil }) { missing.append("round trip not measured") }
                    if reports.contains(where:{ $0.outputMs==nil }) { missing.append("output not measured") }
                    let subtotal=Self.rounded(reports.map(\.knownSubtotalMs).max()).map { "known stages about \($0) ms" } ?? "known stages unavailable"
                    parts.append("total latency unavailable"+suffix+" ("+(missing+[subtotal]).joined(separator:", ")+")")
                }
            }
            return parts.joined(separator:", ")
        }
    }
}
