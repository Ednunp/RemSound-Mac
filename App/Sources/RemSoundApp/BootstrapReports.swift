import Foundation
import RemSoundCore
import RemSoundRuntime

enum BootstrapReports {
    static var helpText: String { "RemSound Mac\nOpen normally for the accessible app.\n--help: show this help\n--install-plugin / --remove-plugin (--uninstall-plugin): isolated fixed sealed-app source or synthetic plugin-payload copy/removal with existing private --config-dir; normal installation and custom folders unsupported; stamped JSON, no plugin load\n--plugin-status: fixed per-user AU/VST3/CLAP metadata JSON, read-only; no plugin load, signature or DAW/audio acceptance; exit 1 for incomplete/invalid/unavailable rows\n--version (-v, --ver): print the packaged version and exit\n--list-profiles (--profiles): list saved profile titles without changing settings and exit\n--list-named-peers (--named-peers): list machine-wide named history and last seen, read-only\n--profile NAME: load one saved profile by name\n--connect IPv4[:port]: select a startup peer (repeatable); without --profile start blank\n--minimized (--minimised, --tray): start in the menu bar without opening the main window\n--devices (--list-devices): print Core Audio names, UIDs and current stream formats and exit (hardware enumeration refused with --config-dir)\n--diagnostics (--diag) [ABSOLUTE-FILE]: print a passive redacted report; optional new private file, never overwrite\n--selftest (--self-test, --smoke-test, --smoketest): hardware-free checks; PARTIAL exit 3, no full live acceptance\n--pack full|feature: with --selftest run the named product catalog; feature conservatively includes all steps without source-change evidence; UNVERIFIED fails, no release acceptance\n--only EXACT-NAME: select one named product step; requires --selftest --pack\nNamed profile logging: native controls require the explicit private empty-root fixture; otherwise 21 assertions and UNVERIFIED\nNamed main-window control specification: live fields, lists, inactive tabs and actual action wiring require the explicit private empty-root native fixture; otherwise UNVERIFIED, zero assertions\nNamed PCM assembly retains its explicit Windows discard-policy gap; allow-list acceptance requires the private isolated receiver fixture\nNamed framing/decryptor: owned isolated receiver fixture required; no normal credential store or physical device acceptance\nAudio round-trip named steps: actual synthetic transport requires explicit private fixture permission; real device capture remains UNVERIFIED, exit 1\n--perftest (--perf-test): three hardware-free resource cycles; own-process metrics, PARTIAL exit 3, no leak verdict\n--seconds N: self-check 1..\(LaunchOptions.maximumSelfCheckSeconds) (default \(LaunchOptions.defaultSelfCheckSeconds)); resource cycles 6..120 (default \(LaunchOptions.defaultResourceCycleSeconds)); offline replay 0.05..60 (default 10, at least recording duration); cooperative, not a capture duration\n--simulate (--simulator) replay --recording ABSOLUTE-FILE [--stream N] [--one-way MS] [--out EXISTING-FOLDER]: offline network/receive replay, fixed seed 1; 0.05..60 simulated seconds, at least the recording duration; JSON to stdout and optional new private simulation-replay.json (never overwrite). Ordinary Opus and custom64/128 use the production native codec/decoder; PCM retains a labelled pure model and unsupported native geometry refuses. Includes fixed native custom64 and ordinary Opus120/480 buffer comparisons. No device acceptance; full sweeps, calibration and other simulator modes remain unsupported\n--log on|off: save machine diagnostic logging for the next launch; retain existing logs\n--silent: play no cue sounds\n--config-dir /absolute/folder: separate private settings, profiles and logs\n--check-accessibility --config-dir /absolute/folder: validate native UI without audio; requires REMSOUND_ALLOW_VISIBLE_UI_TESTS=1 (windows/focus/VoiceOver may change)\n--headless --config-dir /absolute/folder: start isolated and silent without opening a window\n--close (--quit) --config-dir /absolute/folder: request graceful shutdown of one isolated app; never force termination\n--control ACTION --config-dir /absolute/folder: send one local command and exit\n\(ControlCommand.help)" }
    private static let maximumProfiles = 4096
    private static let maximumNamedPeerReportBytes = 256 * 1024
    static func output(for options: LaunchOptions,
        version: () -> String = { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development" },
        profileTitles: (URL) throws -> [String] = { try ProfileStore(directory: $0).list().map(\.title) },
        defaultProfiles: () -> URL = ProfileStore.defaultDirectory,
        namedPeers: (URL?) throws -> [NamedPeerRecord] = RuntimeConfiguration.namedPeersForListing,
        devices:(() throws -> AudioDeviceReportSnapshot)? = nil,
        nativeDevices:() throws -> AudioDeviceReportSnapshot = { try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true) }) throws -> String? {
        guard let report = options.report else { return nil }
        switch report {
        case .diagnostics, .selfCheck, .resourceCycle, .pluginStatus: return nil
        case .version: return "RemSound \(singleLine(version(), limit: 64))\n"
        case .devices:
            if let devices { return try DeviceReportOutput.output(devices()) }
            guard options.configurationDirectory == nil else { throw DeviceReportOutput.Failure.isolated }
            return try DeviceReportOutput.output(nativeDevices())
        case .namedPeers:
            let rows = try namedPeers(options.configurationDirectory)
            guard rows.count <= NamedPeerHistory.maximumRecords else { throw ReportError.tooManyNamedPeers }
            guard !rows.isEmpty else { return "No named peers.\n" }
            let date = DateFormatter(); date.dateFormat = "d MMM yyyy"; date.locale = Locale(identifier: "en_GB")
            let text = "Named peers (\(rows.count)):\n" + rows.map { row in
                let seen = row.lastSeen.map { "last seen " + date.string(from: $0) + (row.lastAddress.map { ", " + singleLine($0, limit: 64) } ?? "") } ?? "not seen yet"
                return "  \(singleLine(row.friendlyName, limit: 80))  (\(singleLine(row.machineName, limit: 160)))  - \(seen)\n"
            }.joined()
            guard text.utf8.count <= maximumNamedPeerReportBytes else { throw ReportError.tooManyNamedPeers }
            return text
        case .profiles:
            let directory = try RuntimeConfiguration.profilesDirectoryForListing(root: options.configurationDirectory, defaultDirectory: defaultProfiles)
            let titles = try profileTitles(directory)
            guard titles.count <= maximumProfiles else { throw ReportError.tooManyProfiles }
            guard !titles.isEmpty else { return "No saved profiles.\n" }
            let names = titles.map { singleLine($0, limit: 80) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return "Saved profiles (\(names.count)):\n" + names.map { "  \($0)\n" }.joined()
        }
    }
    static func singleLine(_ value: String, limit: Int) -> String {
        var result = "", separating = false, count = 0
        for scalar in value.unicodeScalars {
            guard count < limit else { break }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                separating = !result.isEmpty
            default:
                if scalar.properties.isWhitespace { separating = !result.isEmpty; continue }
                if separating { result.append(" "); count += 1; separating = false }
                guard count < limit else { break }
                result.unicodeScalars.append(scalar); count += 1
            }
        }
        return result
    }
    private enum ReportError: LocalizedError {
        case tooManyProfiles, tooManyNamedPeers
        var errorDescription: String? { self == .tooManyProfiles ? "Too many saved profiles to list in one report." : "Too many named peers to list in one report." }
    }
}
