import Foundation

// The control channel advertises bundled filenames rather than accepting paths.
public struct CueControlSelection {
    public let event: CueEvent
    public let choice: String

    public init(_ value: String) throws {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let event = CueEvent(rawValue: String(fields[0])) else {
            throw RuntimeConfigurationError.invalidControlCommand
        }
        let choice = String(fields[1])
        let builtIn = !choice.isEmpty && choice.utf8.count <= 512
            && choice.hasSuffix(".wav") && !choice.contains("/") && !choice.contains("\\")
            && !choice.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard choice == "on" || choice == "off" || builtIn else {
            throw RuntimeConfigurationError.invalidControlCommand
        }
        self.event = event
        self.choice = choice
    }
}
