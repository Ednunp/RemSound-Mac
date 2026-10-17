import Foundation

// Serial Session owner only. Fixed counters, no per-call trace/history or file I/O.
struct SendWorkDiagnostics {
    enum Phase: Int, CaseIterable {
        case encode, nonce, seal, encryptedLayout, frame, relayRoute, udp, wakeFirst, wakeLatest
        var label: String {
            switch self {
            case .encode: return "encode"
            case .nonce: return "random nonce"
            case .seal: return "AES-GCM seal"
            case .encryptedLayout: return "encrypted layout"
            case .frame: return "wire framing"
            case .relayRoute: return "relay route"
            case .udp: return "UDP.send"
            case .wakeFirst: return "wake first-signal-to-consume"
            case .wakeLatest: return "wake latest-signal-to-consume"
            }
        }
    }
    struct Entry { let phase: Phase; let calls: Int; let maximumNs: UInt64 }
    private struct Counter {
        var calls = 0
        var maximumNs: UInt64 = 0
        mutating func note(_ duration: UInt64) {
            calls += 1
            maximumNs = max(maximumNs, duration)
        }
        func entry(_ phase: Phase) -> Entry? {
            calls > 0 ? Entry(phase: phase, calls: calls, maximumNs: maximumNs) : nil
        }
    }
    private var encode = Counter(), nonce = Counter(), seal = Counter()
    private var encryptedLayout = Counter(), frame = Counter(), relayRoute = Counter()
    private var udp = Counter(), wakeFirst = Counter(), wakeLatest = Counter()
    var enabled = true
    func begin() -> UInt64 { enabled ? DispatchTime.now().uptimeNanoseconds : 0 }
    mutating func note(_ phase: Phase, began: UInt64, ended: UInt64? = nil) {
        guard enabled, began > 0 else { return }
        let finished = ended ?? DispatchTime.now().uptimeNanoseconds
        guard finished >= began else { return }
        let duration = finished - began
        switch phase {
        case .encode: encode.note(duration)
        case .nonce: nonce.note(duration)
        case .seal: seal.note(duration)
        case .encryptedLayout: encryptedLayout.note(duration)
        case .frame: frame.note(duration)
        case .relayRoute: relayRoute.note(duration)
        case .udp: udp.note(duration)
        case .wakeFirst: wakeFirst.note(duration)
        case .wakeLatest: wakeLatest.note(duration)
        }
    }
    mutating func noteWake(firstNs: UInt64, latestNs: UInt64) {
        guard enabled, firstNs >= latestNs else { return }
        wakeFirst.note(firstNs)
        wakeLatest.note(latestNs)
    }
    mutating func take() -> [Entry] {
        let entries = [encode.entry(.encode), nonce.entry(.nonce), seal.entry(.seal),
            encryptedLayout.entry(.encryptedLayout), frame.entry(.frame), relayRoute.entry(.relayRoute),
            udp.entry(.udp), wakeFirst.entry(.wakeFirst), wakeLatest.entry(.wakeLatest)].compactMap { $0 }
        let wasEnabled = enabled
        self = Self()
        enabled = wasEnabled
        return entries
    }
    static func describe(_ entries: [Entry]) -> String {
        let values = Phase.allCases.map { phase -> String in
            guard let entry = entries.first(where: { $0.phase == phase }) else { return "\(phase.label) unmeasured" }
            return "\(phase.label) \(entry.calls) calls, wall max \(String(format: "%.6f", Double(entry.maximumNs) / 1_000_000)) ms"
        }
        return "send work interval: " + values.joined(separator: "; ")
            + ". All audio sources together on the serial owner; inclusive route includes UDP, maxima may be different calls, do not add. "
            + "Wake ages include notification publication/coalescing and owner wait, not callback onset. Wall time includes descheduling, not CPU time; not hardware or network latency."
    }
}
