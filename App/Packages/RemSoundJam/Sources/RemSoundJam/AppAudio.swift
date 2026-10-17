import Foundation

// SENDING CHOSEN APPLICATIONS' SOUND (the Mac's copy of the Windows RemSound's "Send specific applications": its
// ReconcileSendAppsList and process-loopback capture).
//
// Windows names an application by its process name and captures its whole process tree. The Mac names it by its
// bundle ID, and an application's sound often comes from helper processes of its own (Chrome's, Spotify's, Teams'),
// whose bundle IDs sit under the application's: "com.google.Chrome.helper". So a chosen application's sound is that of
// every audio process whose bundle ID is the application's or begins with it and a dot. (A process shared by many
// applications - Safari's sound comes from WebKit's - shows as itself, and can be chosen as itself.)
//
// Two lists, as on Windows: "Currently active applications" - the applications with sound processes now, by name,
// then any chosen one that is not running, marked so - and "Remembered applications": every application ever chosen
// on this computer, less those chosen now. Ticking one in either chooses it; unticking stops choosing it.

public struct AudioApp: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let running: Bool
    public let chosen: Bool

    /// The list row, as Windows words it, and whether it is ticked.
    public var row: String { "\(running ? name : name + " (not running)"), \(chosen ? "checked" : "unchecked")" }
}

public enum AppAudio {
    /// The application a sound process belongs to: the longest of `apps` that the bundle ID is, or begins with and a
    /// dot; the bundle ID itself if none.
    public static func owner(of bundleID: String, among apps: Set<String>) -> String {
        apps.filter { bundleID == $0 || bundleID.hasPrefix($0 + ".") }.max { $0.count < $1.count } ?? bundleID
    }

    /// Whether a sound process belongs to a chosen application.
    public static func belongs(_ bundleID: String, to chosen: Set<String>) -> Bool {
        chosen.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    /// The process objects to capture for the chosen applications (Core Audio's ids, in the order given).
    public static func processes(for chosen: Set<String>, in all: [(id: UInt32, bundleID: String)]) -> [UInt32] {
        all.filter { !$0.bundleID.isEmpty && belongs($0.bundleID, to: chosen) }.map(\.id)
    }

    /// The two lists. `processes`: the bundle IDs of the sound processes now (this app's own left out by the caller);
    /// `apps`: the applications running, to fold helpers into; `names`: what to call each (else its bundle ID);
    /// `chosen`: the applications chosen; `remembered`: every one ever chosen here.
    public static func lists(processes: [String], apps: Set<String>, names: [String: String], chosen: [String],
                             remembered: [String]) -> (active: [AudioApp], remembered: [AudioApp]) {
        let chosenSet = Set(chosen)
        let running = Set(processes.filter { !$0.isEmpty }.map { owner(of: $0, among: apps) })
        func name(_ id: String) -> String { names[id] ?? id }
        func byName(_ a: AudioApp, _ b: AudioApp) -> Bool {
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order == .orderedSame ? a.bundleID < b.bundleID : order == .orderedAscending
        }
        let active = running.map { AudioApp(bundleID: $0, name: name($0), running: true, chosen: chosenSet.contains($0)) }
            .sorted(by: byName)
            + chosen.filter { !running.contains($0) }.map { AudioApp(bundleID: $0, name: name($0), running: false, chosen: true) }
                .sorted(by: byName)
        var seen = Set<String>()
        let rest = remembered.filter { !chosenSet.contains($0) && seen.insert($0).inserted }
            .map { AudioApp(bundleID: $0, name: name($0), running: running.contains($0), chosen: false) }
            .sorted(by: byName)
        return (active, rest)
    }

    /// The chosen applications after one is ticked or unticked (kept in the order chosen).
    public static func toggled(_ bundleID: String, in chosen: [String]) -> [String] {
        chosen.contains(bundleID) ? chosen.filter { $0 != bundleID } : chosen + [bundleID]
    }
}
