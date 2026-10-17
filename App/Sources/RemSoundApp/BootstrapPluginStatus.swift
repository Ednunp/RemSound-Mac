import Foundation
import RemSoundRuntime

enum BootstrapPluginStatus {
    struct Result { let text: String; let exitCode: Int }
    static func output(for options: LaunchOptions,
        inspect: (URL?) throws -> PluginInstallationStatus = RuntimeConfiguration.pluginStatusForListing) throws -> Result? {
        guard options.report == .pluginStatus else { return nil }
        let snapshot = try inspect(options.configurationDirectory)
        guard snapshot.schema == 1, snapshot.metadataOnly,
            ["isolated", "user"].contains(snapshot.scope), snapshot.generatedUTC.utf8.count <= 64,
            snapshot.items.map(\.format) == ["AU", "VST3", "CLAP"],
            snapshot.items.allSatisfy({ ($0.version?.utf8.count ?? 0) <= 64 && ($0.build?.utf8.count ?? 0) <= 32 }) else {
            throw RuntimeConfigurationError.invalidSettings
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(snapshot)
        guard bytes.count <= 16 * 1024 else {
            throw RuntimeConfigurationError.invalidSettings
        }
        let complete = snapshot.items.allSatisfy { $0.state == .missing || $0.state == .metadataPresent }
        return .init(text: String(decoding: bytes, as: UTF8.self) + "\n", exitCode: complete ? 0 : 1)
    }
}
