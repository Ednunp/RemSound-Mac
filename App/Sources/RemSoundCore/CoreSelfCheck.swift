import AudioSupport
import Foundation

/// Hardware-free production checks. This scope never represents full application acceptance.
enum CoreSelfCheck {
    enum ID: String, CaseIterable { case wire, format, encryption, ring, opus }
    enum Status { case passed, failed, notRun }
    enum Termination { case completed, cancelled, invalidBudget, invalidClock, deadline }
    struct Step { let id: ID; let status: Status; let assertions: Int }
    struct Report {
        let steps: [Step]; let termination: Termination
        let unverified = ["Physical capture and playback", "UDP session and router", "Native keyboard and spoken output", "Storage and packaged assets"]
        var fullAcceptance: Bool { false }
        var exitCode: Int {
            if steps.contains(where: { $0.status == .failed }) { return 1 }
            switch termination {
            case .completed, .cancelled: return 3
            case .invalidBudget, .invalidClock, .deadline: return 1
            }
        }
    }
    private static let maximumBudget = 8.0
    private static let maximumAssertions = 10_000
    static func run(budget: Double = 8, clock: () -> Double = { ProcessInfo.processInfo.systemUptime },
        cancelled: () -> Bool = { false }, execute: (ID) throws -> Int = check) -> Report {
        var steps=ID.allCases.map { Step(id:$0,status:.notRun,assertions:0) }
        func report(_ termination: Termination) -> Report { .init(steps:steps,termination:termination) }
        guard budget.isFinite, budget > 0, budget <= maximumBudget else { return report(.invalidBudget) }
        if cancelled() { return report(.cancelled) }
        let began=clock();guard began.isFinite, began >= 0 else { return report(.invalidClock) }
        var previous=began
        func boundary() -> Termination? {
            if cancelled() { return .cancelled }
            let now=clock()
            guard now.isFinite, now >= previous else { return .invalidClock }
            previous=now
            return now-began >= budget ? .deadline : nil
        }
        for (index,id) in ID.allCases.enumerated() {
            if let reason=boundary() { return report(reason) }
            var assertions=0,status=Status.failed
            do {
                assertions=try execute(id)
                if (1...maximumAssertions).contains(assertions) { status = .passed }
            } catch { /* A thrown check is a failure; raw errors never enter the value report. */ }
            // Native codec/KDF calls are synchronous. Cancellation/deadlines are cooperative,
            // and must be observed before a late receipt can become a pass or start another check.
            if let reason=boundary() { return report(reason) }
            steps[index] = .init(id:id,status:status,assertions:max(0,min(maximumAssertions,assertions)))
        }
        return report(.completed)
    }
    private enum Failure: Error { case assertion, allocation }
    static func check(_ id: ID) throws -> Int {
        var assertions=0
        func require(_ condition: Bool) throws {
            assertions += 1
            if !condition { throw Failure.assertion }
        }
        switch id {
        case .wire:
            let bytes=Wire.packet(.audio,stream:7,sequence:0x01020304,payload:Data([9,10]))
            try require(bytes == Data([82,77,78,68,1,2,7,0,4,3,2,1,9,10]))
            let packet=Wire.parse(bytes)
            try require(packet?.kind == .audio && packet?.stream == 7 && packet?.sequence == 0x01020304 && packet?.payload == Data([9,10]))
            try require(Wire.parse(Data(bytes.prefix(Wire.headerSize-1))) == nil)
            var bad=bytes;bad[0]=0;try require(Wire.parse(bad) == nil)
            bad=bytes;bad[4]=0;try require(Wire.parse(bad) == nil)
            bad=bytes;bad[5]=0;try require(Wire.parse(bad) == nil)
        case .format:
            let fingerprint=Data([1,2,3,4,5,6,7,8])
            for format in [StreamFormat.pcm(fingerprint),.opus(fingerprint,frames:120),.opusCustom(fingerprint,frames:64)] {
                let bytes=format.encode(),decoded=StreamFormat.parse(bytes)
                try require(bytes.count == 46)
                try require(decoded?.channels == 2 && decoded?.codec == format.codec && decoded?.frames == format.frames && decoded?.fingerprint == fingerprint)
                try require(StreamFormat.parse(Data(bytes.prefix(31))) == nil)
                try require(StreamFormat.parse(Data(bytes.prefix(43)))?.fingerprint.isEmpty == true)
                var bad=bytes;bad[4]=3;try require(StreamFormat.parse(bad) == nil)
            }
        case .encryption:
            let key=try Credentials(password:"RemSound private synthetic self-check"),other=try Credentials(password:"RemSound different synthetic self-check")
            let plain=Data([1,3,5,7,9]),sealed=try key.seal(plain),another=try key.seal(plain)
            try require(try key.open(sealed) == plain)
            try require(sealed.count == plain.count+28 && sealed != another)
            var bad=sealed;bad[bad.count-1] ^= 1
            var rejected=false;do { _=try key.open(bad) } catch { rejected=true };try require(rejected)
            rejected=false;do { _=try other.open(sealed) } catch { rejected=true };try require(rejected)
            rejected=false;do { _=try key.open(Data(sealed.prefix(27))) } catch { rejected=true };try require(rejected)
        case .ring:
            guard let ring=rs_ring_create(8) else { throw Failure.allocation }
            defer { rs_ring_destroy(ring) }
            let samples:[Float]=[0.25,-0.25,0.5,-0.5,0.75,-0.75,1,-1]
            try require(samples.withUnsafeBufferPointer { rs_ring_write_interleaved(ring,$0.baseAddress,4) } == 4)
            try require(rs_ring_available(ring) == 4)
            var left=[Float](repeating:9,count:6),right=left
            let read=left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { rs_ring_read(ring,l.baseAddress,$0.baseAddress,6) } }
            try require(read == 4)
            try require(left == [0.25,0.5,0.75,1,0,0] && right == [-0.25,-0.5,-0.75,-1,0,0])
            try require(rs_ring_available(ring) == 0)
        case .opus:
            guard let encoder=OpusSender(bitrate:320_000),let decoder=rs_opus_decoder(2) else { throw Failure.allocation }
            defer { rs_opus_destroy(decoder) }
            let frames=120,blocks=32
            var energy:Float=0,stereoError:Float=0
            for block in 0..<blocks {
                var input=[Float](repeating:0,count:frames*2)
                for frame in 0..<frames {
                    let tone=Float(sin(Double(block*frames+frame)*2*Double.pi*440/48_000))*0.25
                    input[frame*2]=tone;input[frame*2+1] = -tone
                }
                guard let bytes=encoder.encode(input) else { throw Failure.assertion }
                var decoded=[Float](repeating:0,count:frames*2)
                let count=bytes.withUnsafeBytes { p in decoded.withUnsafeMutableBufferPointer { rs_opus_decode(decoder,p.bindMemory(to:UInt8.self).baseAddress,Int32(bytes.count),$0.baseAddress,Int32(frames)) } }
                try require(count == frames && decoded.allSatisfy(\.isFinite))
                if block >= blocks/2 {
                    for frame in 0..<frames {
                        energy += decoded[frame*2]*decoded[frame*2]
                        stereoError += abs(decoded[frame*2]+decoded[frame*2+1])
                    }
                }
            }
            let observed=Float(frames*blocks/2)
            try require(energy/observed > 0.001)
            try require(stereoError/observed < 0.02)
        }
        return assertions
    }
}
