import Foundation
import RemSoundRuntime

extension ProductTestPack {
    static func checkNamedPeerSettings() -> Step {
        var count = 0, failures: [String] = []
        func require(_ value: Bool, _ code: String) { count += 1; if !value { failures.append(code) } }
        let base = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = base.appendingPathComponent("RemSound-settings-check-" + UUID().uuidString)
        var created = false
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); created = true
            let file = root.appendingPathComponent("settings.plist"), store = try SettingsStore(file: file)
            require(try RuntimeConfiguration.namedPeersForListing(root: root).isEmpty, "history.empty-before-name")
            require(store.setValues(["unrelated": "preserved", "peerAliases": ["192.0.2.9": "profile alias"]]), "history.fixture-settings")
            let book = try NamedPeerHistory(settings: store), date = Date(timeIntervalSince1970: 1700000000)
            require(book.name(machine: "STUDIO", address: nil, friendlyName: "My studio", at: date), "history.explicit-name")
            require(try RuntimeConfiguration.namedPeersForListing(root: root).first?.lastSeen == nil, "history.unseen-not-invented")
            require(!book.noteConnected(machine: "unnamed", address: "192.0.2.8", at: date), "history.no-anonymous-records")
            require(book.noteConnected(machine: "studio", address: "192.0.2.1", at: date), "history.current-connection")
            let read = try RuntimeConfiguration.namedPeersForListing(root: root)
            require(read.count == 1 && read.first?.lastAddress == "192.0.2.1" && read.first?.lastSeen == date, "history.actual-file-roundtrip")
            require(read.first?.friendlyName == "My studio" && read.first?.machineName == "STUDIO", "history.case-identity")
            require(try SettingsStore(file: file).string(forKey: "unrelated") == "preserved", "history.preserve-unrelated")
            let saved = try Data(contentsOf: file), later = date.addingTimeInterval(60)
            require(book.noteConnected(machine: "STUDIO", address: "192.0.2.1", at: later), "history.timestamp-current")
            require(try Data(contentsOf: file) == saved, "history.no-write-per-refresh")
            require(book.flush(), "history.owner-stop-flush")
            require(try RuntimeConfiguration.namedPeersForListing(root: root).first?.lastSeen == later, "history.flushed-time")
            if let row = book.entries.first {
                require(book.rename(row, friendlyName: "Managed studio"), "history.management-rename")
                require(book.entries.first?.lastSeen == later, "history.management-preserves-observation")
                require(!book.rename(row, friendlyName: "Stale modal"), "history.management-stale-refusal")
                require(book.forget(book.entries), "history.management-delete")
                require(!book.noteConnected(machine: "STUDIO", address: "192.0.2.1", at: later), "history.no-resurrection")
            } else { require(false, "history.management-missing-record") }
            require(book.name(machine: "STUDIO", address: nil, friendlyName: ""), "history.explicit-clear")
            require(try RuntimeConfiguration.namedPeersForListing(root: root).isEmpty, "history.empty-after-clear")
            require(try SettingsStore(file: file).dictionary(forKey: "peerAliases")?["192.0.2.9"] as? String == "profile alias", "history.no-profile-alias-migration")
        } catch { count += 1; failures.append("history.settings-path-error") }
        if created { do { try FileManager.default.removeItem(at: root) } catch { failures.append("history.fixture-cleanup") } }
        let status = failures.isEmpty ? "UNVERIFIED" : "FAIL"
        failures.append("theme-tabs-shaping-and-recording-defaults-unverified")
        return .init(name: "v5 settings and shaping round-trip", status: status, assertions: count, failures: failures)
    }
}
