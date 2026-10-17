import Foundation
import RemSoundCore
import RemSoundRuntime

enum BootstrapPluginCommand {
    struct Result { let text: String; let exitCode: Int }
    static func output(for options: LaunchOptions) throws -> Result? {
        guard let action = options.pluginAction else { return nil }
        let receipt = PluginInstallationCommand.run(action: action, isolatedRoot: options.configurationDirectory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        guard data.count <= 16 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw RuntimeConfigurationError.invalidPluginOptions
        }
        return .init(text: text + "\n", exitCode: ["installed", "removed"].contains(receipt.status) ? 0 : 1)
    }
}
