import Foundation
import RemSoundCore
import RemSoundRuntime

/// Pure support-report formatting. Collection and publication must finish before a CLI flag is exposed.
enum PassiveDiagnosticReport {
    enum Failure: Error { case invalidMetadata, tooLarge }
    private static let maximumEntries = 4096
    private static let maximumDevices = 1024
    private static let maximumStreams = 256
    private static let maximumBytes = 256 * 1024
    static func output(version: String, system: String, architecture: String,
        profiles: ProfileDiagnosticInventory?, devices: AudioDeviceReportSnapshot?,
        metadata: DiagnosticRuntimeMetadata? = nil, profileUnavailable: Bool = false, deviceUnavailable: Bool = false) throws -> String {
        var lines: [String] = [], bytes = 0
        func append(_ text: String) throws {
            let added = text.utf8.count + 1
            guard added <= maximumBytes - bytes else { throw Failure.tooLarge }
            bytes += added; lines.append(text)
        }
        try append("RemSound diagnostics (passive)")
        try append("Version: " + BootstrapReports.singleLine(version, limit: 64))
        try append("System: " + BootstrapReports.singleLine(system, limit: 128))
        try append("Architecture: " + BootstrapReports.singleLine(architecture, limit: 16))
        try append("Privacy: profile identities, titles and contents; device names and UIDs; credential fields and paths are omitted.")
        if let metadata {
            guard (0...1024).contains(metadata.logFiles), metadata.settingsBytes.map({ $0 >= 0 }) ?? true,
                metadata.logBytes.map({ $0 >= 0 }) ?? true else { throw Failure.invalidMetadata }
            try append("Settings metadata: " + metadata.settings.rawValue + " (values not read).")
            if let size = metadata.settingsBytes { try append("Settings file size: \(size) bytes.") }
            try append("Log metadata: \(metadata.logFiles) regular file(s), \(metadata.logBytes.map(String.init) ?? "unknown") bytes; \(metadata.logsComplete ? "complete" : "incomplete") snapshot.")
        }
        if let profiles {
            let counts = [profiles.readable, profiles.readOnly, profiles.unreadable, profiles.deferred]
            guard counts.allSatisfy({ (0...maximumEntries).contains($0) }), profiles.readOnly <= profiles.readable,
                profiles.readable + profiles.unreadable + profiles.deferred <= maximumEntries,
                !profiles.complete || profiles.deferred == 0 else { throw Failure.invalidMetadata }
            try append("Profiles: \(profiles.readable) readable, \(profiles.readOnly) read-only, \(profiles.unreadable) unreadable, \(profiles.deferred) deferred.")
            try append(profiles.complete ? "Profile scan: complete within limits; unreadable entries remain unreadable." :
                "Profile scan: incomplete; work limits, changes or directory errors prevented a full inventory.")
        } else { try append(profileUnavailable ? "Profiles: unavailable; existing data was preserved." : "Profiles: not collected.") }
        if let devices {
            for (direction, items) in [("Inputs", devices.inputs), ("Outputs", devices.outputs)] {
                guard items.count <= maximumDevices else { throw Failure.invalidMetadata }
                try append("\(direction): \(items.count) device(s).")
                for (index, item) in items.enumerated() {
                    guard item.formats.count <= maximumStreams else { throw Failure.invalidMetadata }
                    try append("  Device \(index + 1)\(item.isDefault ? " [default]" : ""):")
                    if item.formats.isEmpty { try append("    Format unavailable.") }
                    for (stream, format) in item.formats.enumerated() {
                        guard let format else { try append("    Stream \(stream + 1): format unavailable."); continue }
                        guard format.isValidForReport else { throw Failure.invalidMetadata }
                        let bits = format.bitsPerChannel == 0 ? "bit depth unavailable" : "\(format.bitsPerChannel)-bit"
                        try append("    Stream \(stream + 1): \(format.sampleRate) Hz, \(format.channels) channels, \(bits).")
                    }
                }
            }
        } else { try append(deviceUnavailable ? "Devices: unavailable; no supported-route conclusion." : (metadata == nil ? "Devices: not collected." : "Devices: not collected (isolated hardware guard or missing collection).")) }
        try append("Current stream metadata is not a supported-route or live audio test.")
        try append(metadata == nil ? "Settings, log contents, audio permissions and live probes: not collected by this formatter." : "Settings values and log contents were not read. Credential stores, audio permissions and live probes were not queried.")
        return lines.joined(separator: "\n") + "\n"
    }
}
