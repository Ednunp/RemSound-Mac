import Foundation
import RemSoundCore
import RemSoundRuntime

enum BootstrapDiagnostics {
    enum Result: Equatable { case standardOutput(String), saved, publicationUncertain }
    static func result(for options: LaunchOptions,
        metadata: (URL?) throws -> DiagnosticRuntimeMetadata = DiagnosticRuntimeMetadata.collect,
        profiles: (URL) throws -> ProfileDiagnosticInventory = { try ProfileStore(directory: $0).diagnosticInventory() },
        defaultProfiles: () -> URL = ProfileStore.defaultDirectory,
        devices: () throws -> AudioDeviceReportSnapshot = { try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration: true) },
        fixtureDevices: AudioDeviceReportSnapshot? = nil,
        publish: (String, URL) throws -> DiagnosticReportPublication = DiagnosticReportFile.publish,
        version: () -> String = { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development" }) throws -> Result? {
        guard options.report == .diagnostics else { return nil }
        // Validate the explicit scope before any normal/default provider can be consulted.
        let facts = try metadata(options.configurationDirectory)
        let directory = try RuntimeConfiguration.profilesDirectoryForListing(root: options.configurationDirectory, defaultDirectory: defaultProfiles)
        var profileUnavailable = false, deviceUnavailable = false
        let inventory: ProfileDiagnosticInventory?
        do { inventory = try profiles(directory) }
        catch { inventory = nil; profileUnavailable = true }
        let hardware: AudioDeviceReportSnapshot?
        if let fixtureDevices { hardware = fixtureDevices }
        else if options.configurationDirectory != nil { hardware = nil }
        else {
            do { hardware = try devices() }
            catch { hardware = nil; deviceUnavailable = true }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let report = try PassiveDiagnosticReport.output(version: version(),
            system: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture,
            profiles: inventory, devices: hardware, metadata: facts,
            profileUnavailable: profileUnavailable, deviceUnavailable: deviceUnavailable)
        guard let destination = options.diagnosticOutput else { return .standardOutput(report) }
        return try publish(report, destination) == .published ? .saved : .publicationUncertain
    }
    #if DEBUG
    static func fixtureDevices(for options: LaunchOptions) throws -> AudioDeviceReportSnapshot? {
        var environment = ProcessInfo.processInfo.environment
        guard options.report == .diagnostics, environment["REMSOUND_TEST_DIAGNOSTICS_REPORT"] == "1" else { return nil }
        environment["REMSOUND_TEST_PEER_MOVE_CHECK"] = "1"
        guard HeadlessPeerMoveCheckPolicy.accepts(root: options.configurationDirectory, headless: true,
            silent: options.silent, environment: environment) else { return nil }
        _ = try RuntimeConfiguration.profilesDirectoryForListing(root: options.configurationDirectory, defaultDirectory: ProfileStore.defaultDirectory)
        return .init(inputs: [.init(uid: "private fixture UID", name: "private fixture name", isDefault: true,
            formats: [.init(sampleRate: 48000, channels: 2, bitsPerChannel: 32, encoding: "private fixture encoding")])], outputs: [])
    }
    #endif
}
