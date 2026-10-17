import Foundation

public enum LaunchReport: Equatable, Sendable { case version, profiles, namedPeers, devices, diagnostics, selfCheck, resourceCycle, pluginStatus }

public struct StartupOptions: Equatable, Sendable {
    public var profileName: String?
    public var connectPeers: [String] = []
    public var startMinimized = false
    public init() {}
    var hasOverrides: Bool { profileName != nil || !connectPeers.isEmpty || startMinimized }
    static let maximumProfileNameBytes = 512
    static let maximumPeers = 64
    private static let audioPort = 47830
    static func numericPeer(_ raw:String) -> String? {
        guard raw.utf8.count <= 64 else { return nil }
        let parts = raw.trimmingCharacters(in:.whitespacesAndNewlines).split(separator:":",omittingEmptySubsequences:false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let numbers = parts[0].split(separator:".",omittingEmptySubsequences:false)
        guard numbers.count == 4, numbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && UInt8($0) != nil }) else { return nil }
        let port:Int
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                let value = UInt16(parts[1]), value != 0 else { return nil }
            port = Int(value)
        } else { port = audioPort }
        let host = numbers.map { String(UInt8($0)!) }.joined(separator:".")
        return port == audioPort ? host : "\(host):\(port)"
    }
}

public enum PluginToolAction: String, Sendable { case install, remove }

public struct LaunchOptions {
    public var pluginAction: PluginToolAction?
    public var simulationReplay: SimulationReplayOptions?
    public static let defaultSelfCheckSeconds = 3
    public static let maximumSelfCheckSeconds = 8
    public var selfTestPack: String?
    public var selfTestOnly: String?
    public var selfCheckSeconds = Self.defaultSelfCheckSeconds
    public static let defaultResourceCycleSeconds = 15
    public static let resourceCycleSecondsRange = 6...120
    public var resourceCycleSeconds = Self.defaultResourceCycleSeconds
    public var diagnosticLoggingEnabled: Bool?
    public var startup = StartupOptions()
    private static let maximumDiagnosticPathBytes = 1024
    public var diagnosticOutput: URL?
    public var report: LaunchReport?
    public var configurationDirectory: URL?
    public var silent = false
    public var checkAccessibility = false
    public var help = false
    public var headless = false
    public var controlRequest: ControlRequest?

    public static func parse(_ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> LaunchOptions {
        var result = LaunchOptions()
        var index = 0
        var action: String?, value: String?, device: String?, pair: String?
        var secondsSeen = false
        var secondsValue: String?
        var simulationMode: String?, recordingPath: String?, outputPath: String?
        var replayStream: Int?, replayOneWay: Double?
        while index < arguments.count {
            let argument = arguments[index]
            switch argument.lowercased() {
            case "--install-plugin", "--uninstall-plugin", "--remove-plugin":
                guard result.pluginAction == nil else { throw RuntimeConfigurationError.invalidPluginOptions }
                result.pluginAction = argument.lowercased() == "--install-plugin" ? .install : .remove
            case "--simulate", "--simulator", "--recording", "--out", "--stream", "--one-way":
                index += 1
                guard index < arguments.count else { throw RuntimeConfigurationError.invalidSimulationOptions }
                let value = arguments[index]
                switch argument.lowercased() {
                case "--simulate", "--simulator":
                    guard simulationMode == nil, value == "replay" else { throw RuntimeConfigurationError.invalidSimulationOptions }
                    simulationMode = value
                case "--recording", "--out":
                    guard value.hasPrefix("/"), value != "/", value.utf8.count <= 1024,
                        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                        argument.lowercased() == "--out" || !value.hasSuffix("/") else { throw RuntimeConfigurationError.invalidSimulationOptions }
                    if argument.lowercased() == "--recording" {
                        guard recordingPath == nil else { throw RuntimeConfigurationError.invalidSimulationOptions }; recordingPath = value
                    } else { guard outputPath == nil else { throw RuntimeConfigurationError.invalidSimulationOptions }; outputPath = value }
                case "--stream":
                    guard replayStream == nil, let number = Int(value), (-1...63).contains(number) else { throw RuntimeConfigurationError.invalidSimulationOptions }; replayStream = number
                default:
                    guard replayOneWay == nil, let number = Double(value), number.isFinite, (0...2000).contains(number) else { throw RuntimeConfigurationError.invalidSimulationOptions }; replayOneWay = number
                }

            case "--config-dir":
                index += 1
                guard result.configurationDirectory == nil, index < arguments.count,
                    arguments[index].hasPrefix("/"), arguments[index] != "/" else {
                    throw RuntimeConfigurationError.invalidConfigurationDirectory
                }
                result.configurationDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
                    .standardizedFileURL
            case "--selftest", "--self-test", "--smoke-test", "--smoketest":
                guard result.report == nil else { throw RuntimeConfigurationError.invalidSelfCheckOptions }
                result.report = .selfCheck
            case "--pack":
                index += 1
                guard result.selfTestPack == nil, index < arguments.count,
                    ["full","feature"].contains(arguments[index]) else { throw RuntimeConfigurationError.invalidSelfCheckOptions }
                result.selfTestPack=arguments[index]
            case "--only":
                index += 1
                guard result.selfTestOnly == nil, index < arguments.count,
                    !arguments[index].isEmpty, arguments[index].utf8.count <= 512,
                    !arguments[index].unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else { throw RuntimeConfigurationError.invalidSelfCheckOptions }
                result.selfTestOnly=arguments[index]
            case "--perftest", "--perf-test":
                guard result.report == nil else { throw RuntimeConfigurationError.invalidResourceCycleOptions }
                result.report = .resourceCycle
            case "--seconds":
                index += 1
                guard !secondsSeen, index < arguments.count else { throw RuntimeConfigurationError.invalidSelfCheckOptions }
                secondsSeen = true; secondsValue = arguments[index]
            case "--diagnostics", "--diag":
                guard result.report == nil else { throw RuntimeConfigurationError.invalidControlCommand }
                result.report = .diagnostics
                if index + 1 < arguments.count && !arguments[index + 1].hasPrefix("-") {
                    index += 1
                    let path = arguments[index]
                    guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"), !path.utf8.contains(0), path.utf8.count < Self.maximumDiagnosticPathBytes else {
                        throw RuntimeConfigurationError.invalidConfigurationDirectory
                    }
                    result.diagnosticOutput = URL(fileURLWithPath: path).standardizedFileURL
                }
            case "--plugin-status":
                guard result.report == nil else { throw RuntimeConfigurationError.invalidControlCommand }
                result.report = .pluginStatus
            case "--version", "-v", "--ver", "--list-profiles", "--profiles", "--devices", "--list-devices", "--named-peers", "--list-named-peers":
                guard result.report == nil else { throw RuntimeConfigurationError.invalidControlCommand }
                result.report = ["--named-peers", "--list-named-peers"].contains(argument.lowercased()) ? .namedPeers : (["--devices", "--list-devices"].contains(argument.lowercased()) ? .devices : (["--version", "-v", "--ver"].contains(argument.lowercased()) ? .version : .profiles))
            case "--profile":
                index += 1
                guard result.startup.profileName == nil, index < arguments.count else { throw RuntimeConfigurationError.invalidStartupOptions }
                let name = arguments[index]
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    name.utf8.count <= StartupOptions.maximumProfileNameBytes,
                    !name.hasPrefix("-"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else {
                    throw RuntimeConfigurationError.invalidStartupOptions
                }
                result.startup.profileName = name
            case "--connect":
                index += 1
                guard index < arguments.count, result.startup.connectPeers.count < StartupOptions.maximumPeers,
                    let address = StartupOptions.numericPeer(arguments[index]) else { throw RuntimeConfigurationError.invalidStartupOptions }
                result.startup.connectPeers.append(address)
            case "--minimized", "--minimised", "--tray": result.startup.startMinimized = true
            case "--log":
                index += 1
                guard result.diagnosticLoggingEnabled == nil, index < arguments.count else { throw RuntimeConfigurationError.invalidControlCommand }
                switch arguments[index].lowercased() {
                case "on", "true", "1", "enable", "enabled", "yes": result.diagnosticLoggingEnabled = true
                case "off", "false", "0", "disable", "disabled", "no": result.diagnosticLoggingEnabled = false
                default: throw RuntimeConfigurationError.invalidControlCommand
                }
            case "--close", "--quit":
                guard action == nil else { throw RuntimeConfigurationError.invalidControlCommand }
                action = "quit"
            case "--silent": result.silent = true
            case "--headless": result.headless = true
            case "--control", "--value", "--device", "--pair":
                index += 1
                guard index < arguments.count else { throw RuntimeConfigurationError.invalidControlCommand }
                switch argument.lowercased() {
                case "--control":
                    guard action == nil else { throw RuntimeConfigurationError.invalidControlCommand }
                    action = arguments[index]
                case "--value":
                    guard value == nil else { throw RuntimeConfigurationError.invalidControlCommand }
                    value = arguments[index]
                case "--device":
                    guard device == nil else { throw RuntimeConfigurationError.invalidControlCommand }
                    device = arguments[index]
                default:
                    guard pair == nil else { throw RuntimeConfigurationError.invalidControlCommand }
                    pair = arguments[index]
                }
            case "--check-accessibility": result.checkAccessibility = true
            case "--help", "-h": result.help = true
            default:
                // Launch Services supplies this legacy process-serial-number argument on some Macs.
                guard argument.hasPrefix("-psn_") else { throw RuntimeConfigurationError.unknownOption }
            }
            index += 1
        }
        guard result.pluginAction == nil || (result.report == nil && action == nil && value == nil && device == nil && pair == nil
            && !result.headless && !result.checkAccessibility && !result.startup.hasOverrides
            && result.diagnosticLoggingEnabled == nil && simulationMode == nil && !secondsSeen) else {
            throw RuntimeConfigurationError.invalidPluginOptions
        }
        if simulationMode != nil {
            guard let path = recordingPath, result.report == nil, result.selfTestPack == nil,
                result.selfTestOnly == nil, action == nil, value == nil, device == nil, pair == nil,
                result.diagnosticLoggingEnabled == nil, !result.headless, !result.checkAccessibility,
                !result.startup.hasOverrides else { throw RuntimeConfigurationError.invalidSimulationOptions }
            let seconds = secondsValue.flatMap(Double.init) ?? (secondsSeen ? .nan : 10)
            guard seconds.isFinite, (0.05...60).contains(seconds) else { throw RuntimeConfigurationError.invalidSimulationOptions }
            result.simulationReplay = .init(recording: URL(fileURLWithPath: path).standardizedFileURL,
                outputDirectory: outputPath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL },
                seconds: seconds, stream: replayStream ?? -1, oneWayMs: replayOneWay)
            secondsValue = nil
        } else if recordingPath != nil || outputPath != nil || replayStream != nil || replayOneWay != nil {
            throw RuntimeConfigurationError.invalidSimulationOptions
        }
        guard result.selfTestPack == nil || result.report == .selfCheck,
            result.selfTestOnly == nil || (result.report == .selfCheck && result.selfTestPack != nil) else { throw RuntimeConfigurationError.invalidSelfCheckOptions }
        if let rawSeconds = secondsValue {
            guard let seconds = Int(rawSeconds) else { throw RuntimeConfigurationError.invalidSelfCheckOptions }
            switch result.report {
            case .selfCheck:
                guard (1...Self.maximumSelfCheckSeconds).contains(seconds) else { throw RuntimeConfigurationError.invalidSelfCheckOptions }
                result.selfCheckSeconds = seconds
            case .resourceCycle:
                guard Self.resourceCycleSecondsRange.contains(seconds) else { throw RuntimeConfigurationError.invalidResourceCycleOptions }
                result.resourceCycleSeconds = seconds
            default: throw RuntimeConfigurationError.invalidSelfCheckOptions
            }
        }
        guard result.diagnosticLoggingEnabled == nil || (result.report == nil && action == nil && !result.headless && !result.checkAccessibility && !result.startup.hasOverrides && value == nil && device == nil && pair == nil) else {
            throw RuntimeConfigurationError.invalidControlCommand
        }
        guard !result.startup.hasOverrides || (result.report == nil && action == nil && !result.checkAccessibility) else {
            throw RuntimeConfigurationError.invalidStartupOptions
        }
        guard result.report == nil || !(result.headless || result.checkAccessibility || action != nil) else {
            throw RuntimeConfigurationError.invalidControlCommand
        }
        guard !result.checkAccessibility || result.configurationDirectory != nil || result.help else {
            throw RuntimeConfigurationError.accessibilityRequiresIsolation
        }
        guard !(result.headless && (action != nil || result.checkAccessibility)),
            !(action != nil && result.checkAccessibility),
            (action != nil || (value == nil && device == nil && pair == nil)) else {
            throw RuntimeConfigurationError.invalidControlCommand
        }
        guard !(result.headless || action != nil) || result.configurationDirectory != nil || result.help else {
            throw RuntimeConfigurationError.controlRequiresIsolation
        }
        guard !result.checkAccessibility || result.help || environment["REMSOUND_ALLOW_VISIBLE_UI_TESTS"] == "1" else {
            throw RuntimeConfigurationError.accessibilityRequiresVisibleTestOptIn
        }
        if let action {
            var arguments = [String: String]()
            if let value { arguments["value"] = value }
            if let device { arguments["device"] = device }
            if let pair { arguments["pair"] = pair }
            let request = ControlRequest(action: action, arguments: arguments)
            if action == "password" {
                guard arguments.isEmpty else { throw RuntimeConfigurationError.invalidControlCommand }
            } else { _ = try ControlCommand(request) }
            result.controlRequest = request
        }
        return result
    }
}

public enum RuntimeConfigurationError: Error, LocalizedError {
    case invalidConfigurationDirectory, unsafeConfigurationDirectory, invalidSettings, unknownOption, invalidPluginOptions
    case accessibilityRequiresIsolation
    case accessibilityRequiresVisibleTestOptIn
    case controlRequiresIsolation, invalidControlCommand, invalidStartupOptions, invalidSelfCheckOptions, invalidResourceCycleOptions, invalidSimulationOptions

    public var errorDescription: String? {
        switch self {
        case .invalidConfigurationDirectory: return "--config-dir needs one absolute folder path."
        case .unsafeConfigurationDirectory: return "The isolated configuration folder must be owned by this user, private, and free of symbolic links."
        case .invalidSettings: return "The isolated settings file is invalid or cannot be saved."
        case .invalidPluginOptions: return "Use one --install-plugin or --remove-plugin (--uninstall-plugin). Only an existing private --config-dir is supported in this slice; fixed plugin-payload input and fixed per-user-shaped isolated targets, no custom folder or normal installation."
        case .unknownOption: return "Unknown RemSound option. Use --help for supported options."
        case .accessibilityRequiresIsolation: return "--check-accessibility requires --config-dir to protect saved settings."
        case .accessibilityRequiresVisibleTestOptIn: return "Native accessibility checks can open windows, move focus and affect VoiceOver. After agreeing a test window, set REMSOUND_ALLOW_VISIBLE_UI_TESTS=1. No UI check was run."
        case .controlRequiresIsolation: return "--headless, --control, --close and --quit require --config-dir to protect saved settings."
        case .invalidSelfCheckOptions: return "Use one --selftest mode with --seconds from 1 to \(LaunchOptions.maximumSelfCheckSeconds), or --perftest with --seconds from 6 to 120. This is a maximum cooperative budget, not a capture duration. Named product packs use --selftest --pack full|feature and optional --only with an exact catalog name. Unverified product steps fail the pack."
        case .invalidResourceCycleOptions: return "Use one hardware-free --perftest mode and an optional --seconds from 6 to 120 (default 15). Three memory-work cycles report own-process observations, not physical capture or a leak verdict. Filters and other scopes are unsupported."
        case .invalidSimulationOptions: return "Use --simulate replay --recording ABSOLUTE-FILE, optional --stream -1...63, --one-way 0...2000 milliseconds, --seconds 0.05...60, and --out an existing owned folder. Other simulator modes and live/control options are unsupported in this slice."
        case .invalidStartupOptions: return "Invalid startup options. Use one profile name, numeric IPv4 peers with optional ports, and at most 64 --connect options. Startup options cannot be combined with reports or control actions."
        case .invalidControlCommand: return "Invalid control action or arguments. Use --help; password values are accepted only through piped standard input."
        }
    }
}
