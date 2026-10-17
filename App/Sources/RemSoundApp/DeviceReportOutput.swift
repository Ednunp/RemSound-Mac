import Foundation
import RemSoundCore
import RemSoundRuntime

enum DeviceReportOutput {
    private static let maximumDevices = 1024
    private static let maximumStreams = 256
    private static let maximumOutputBytes = 2 * 1024 * 1024
    enum Failure: LocalizedError {
        case isolated, invalid
        var errorDescription: String? {
            self == .isolated ? "--devices cannot enumerate hardware in an isolated configuration. No device query was made." :
                "Device metadata is invalid or exceeds the report limits. No partial device report was produced."
        }
    }
    private static func displayUID(_ value: String) -> String {
        guard value.unicodeScalars.count <= 256 else { return "(omitted: longer than 256 characters)" }
        let needsEscape = value.first?.isWhitespace == true || value.last?.isWhitespace == true || value.unicodeScalars.contains {
            $0.value == 34 || $0.value == 92 || [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }
        guard needsEscape else { return value }
        var escaped = "\""
        for scalar in value.unicodeScalars {
            if scalar.value == 34 { escaped += "\\\""; continue }
            if scalar.value == 92 { escaped += "\\\\"; continue }
            if [.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory) {
                if scalar.value <= 0xffff { escaped += String(format: "\\u%04x", scalar.value) }
                else {
                    let supplementary = scalar.value - 0x10000
                    escaped += String(format: "\\u%04x\\u%04x", 0xd800 + (supplementary >> 10), 0xdc00 + (supplementary & 0x3ff))
                }
            } else { escaped.unicodeScalars.append(scalar) }
        }
        return escaped + "\""
    }
    static func output(_ snapshot: AudioDeviceReportSnapshot) throws -> String {
        guard snapshot.inputs.count <= maximumDevices, snapshot.outputs.count <= maximumDevices else { throw Failure.invalid }
        var lines: [String] = [], bytes = 0
        func append(_ value: String) throws {
            let count = value.utf8.count + 1
            guard count <= maximumOutputBytes - bytes else { throw Failure.invalid }
            bytes += count; lines.append(value)
        }
        try append("Core Audio devices (current stream formats):")
        for (header, devices) in [("Inputs:", snapshot.inputs), ("Outputs:", snapshot.outputs)] {
            try append(header)
            if devices.isEmpty { try append("  (none)"); continue }
            let sorted = devices.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.uid < $1.uid : order == .orderedAscending
            }
            for device in sorted {
                guard device.formats.count <= maximumStreams else { throw Failure.invalid }
                let name = BootstrapReports.singleLine(device.name, limit: 120)
                try append("  \(name.isEmpty ? "(unnamed)" : name)\(device.isDefault ? " [default]" : "")")
                try append("    UID: \(displayUID(device.uid))")
                if device.formats.isEmpty { try append("    Format unavailable") }
                for (index, format) in device.formats.enumerated() {
                    guard let format else { try append("    Stream \(index + 1): format unavailable"); continue }
                    guard format.isValidForReport else { throw Failure.invalid }
                    let rate = format.sampleRate.rounded() == format.sampleRate ? String(Int(format.sampleRate)) : String(format.sampleRate)
                    let bits = format.bitsPerChannel == 0 ? "bit depth unavailable" : "\(format.bitsPerChannel)-bit"
                    try append("    Stream \(index + 1): \(rate) Hz, \(format.channels) channels, \(bits) \(BootstrapReports.singleLine(format.encoding, limit: 64))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

#if DEBUG
extension BootstrapReports {
    static func fixtureDevices(for options: LaunchOptions) throws -> (() throws -> AudioDeviceReportSnapshot)? {
        var environment = ProcessInfo.processInfo.environment
        guard environment["REMSOUND_TEST_DEVICES_REPORT"] == "1", options.report == .devices else { return nil }
        environment["REMSOUND_TEST_PEER_MOVE_CHECK"] = "1"
        guard HeadlessPeerMoveCheckPolicy.accepts(root: options.configurationDirectory,
            headless: true, silent: options.silent, environment: environment) else { return nil }
        _ = try RuntimeConfiguration.profilesDirectoryForListing(root: options.configurationDirectory, defaultDirectory: ProfileStore.defaultDirectory)
        return {
            .init(inputs: [.init(uid: "fixture-input", name: "Fixture input", isDefault: true,
                formats: [AudioDeviceReportFormat(sampleRate: 48000, channels: 2, bitsPerChannel: 32, encoding: "float PCM")])], outputs: [])
        }
    }
}
#endif
