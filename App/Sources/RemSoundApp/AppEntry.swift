import RemSoundJam
import RemSoundRuntime
import SwiftUI

private final class ClosingSettingsView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let hostWindow = window else { return }
        DispatchQueue.main.async { [weak hostWindow] in hostWindow?.close() }
    }
}

private struct CloseUnusedSettingsScene: NSViewRepresentable {
    func makeNSView(context: Context) -> ClosingSettingsView { ClosingSettingsView() }
    func updateNSView(_ view: ClosingSettingsView, context: Context) {}
}

@main
enum RemSoundBootstrap {
    static func main() {
        do {
            let options = try LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print(BootstrapReports.helpText)
                return
            }
            if let status = try BootstrapPluginStatus.output(for: options) {
                FileHandle.standardOutput.write(Data(status.text.utf8))
                exit(Int32(status.exitCode))
            }
            if let simulation = try BootstrapSimulation.output(for: options) {
                FileHandle.standardOutput.write(Data(simulation.text.utf8))
                if let notice = simulation.notice { FileHandle.standardError.write(Data((notice + "\n").utf8)) }
                exit(Int32(simulation.exitCode))
            }
            if let result = try BootstrapPluginCommand.output(for: options) {
                FileHandle.standardOutput.write(Data(result.text.utf8))
                exit(Int32(result.exitCode))
            }
            #if DEBUG
            let reportOutput = try BootstrapReports.output(for: options, devices: BootstrapReports.fixtureDevices(for: options))
            #else
            let reportOutput = try BootstrapReports.output(for: options)
            #endif
            if let report = reportOutput {
                FileHandle.standardOutput.write(Data(report.utf8))
                return
            }
            #if DEBUG
            let diagnostics = try BootstrapDiagnostics.result(for: options, fixtureDevices: BootstrapDiagnostics.fixtureDevices(for: options))
            #else
            let diagnostics = try BootstrapDiagnostics.result(for: options)
            #endif
            if let diagnostics {
                switch diagnostics {
                case .standardOutput(let text): FileHandle.standardOutput.write(Data(text.utf8))
                case .saved: print("Saved the complete diagnostic report as a private file. Existing files were not replaced.")
                case .publicationUncertain:
                    FileHandle.standardError.write(Data("The report was created, but its final location or temporary-file cleanup could not be confirmed.\n".utf8))
                    exit(1)
                }
                return
            }
            if let result = try BootstrapSelfCheck.output(for: options, nativeProfileLogging: { BootstrapProfileLogging.run(for: options) }, nativeControlSpecifications: { BootstrapControlSpecifications.run(for: options) }, nativeDialogs: { BootstrapDialogAudit.run(for: options, controls: $0) }, nativeEventClaims: { BootstrapEventClaims.run(for: options) }, nativeAudioAxis: { BootstrapAudioAxisAudit.run(for: options) }, nativeContextHelp: { BootstrapContextHelp.run(for: options) }) {
                FileHandle.standardOutput.write(Data(result.text.utf8))
                exit(Int32(result.exitCode))
            }
            if let result = try BootstrapResourceCycle.output(for: options) {
                FileHandle.standardOutput.write(Data(result.text.utf8))
                exit(Int32(result.exitCode))
            }
            if let result = try BootstrapLogging.output(for: options, store: {
                try RuntimeConfiguration.settingsForStandaloneCommand(root: options.configurationDirectory)
            }) {
                FileHandle.standardOutput.write(Data(result.utf8))
                return
            }
            if var request = options.controlRequest {
                if request.action == "password" {
                    request = ControlRequest(action: "password", arguments: ["password": try ControlPasswordInput.read()])
                }
                // A client never constructs a runtime, delegate or settings store, even when no server answers.
                let socket = options.configurationDirectory!.appendingPathComponent("control.sock")
                let reply = try LocalControlClient.send(request, to: socket)
                FileHandle.standardOutput.write(try JSONEncoder().encode(reply))
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(reply.status == .ok ? 0 : reply.status == .waiting ? 3 : 1)
            }
            try AppRuntime.prepare(options)
            RemSoundApplication.main()
        } catch {
            FileHandle.standardError.write(Data("RemSound: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }
}

struct RemSoundApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            CloseUnusedSettingsScene()
        }
            .commands {
                RemSoundCommands(delegate: delegate)
                JamCommands(jam: delegate.jam)
            }
    }
}

struct RemSoundCommands: Commands {
    @ObservedObject var delegate: AppDelegate

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About RemSound") { delegate.performMenuAction(.about) }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Preferences…") { delegate.performMenuAction(.preferences) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .appSettings) {
            Button("Show RemSound") { delegate.performMenuAction(.showWindow) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Manage Named Peers…") { delegate.performMenuAction(.namedPeers) }
            Button("Open Log Folder") { delegate.performMenuAction(.openLogs) }
            Toggle("Launch at Login", isOn: Binding(
                get: { delegate.menuLaunchAtLogin },
                set: { _ in delegate.performMenuAction(.toggleLaunchAtLogin) }))
            Button("Forget Saved Password") { delegate.performMenuAction(.forgetSavedPassword) }
        }
        CommandGroup(after: .toolbar) {
            Button("Connectivity") { delegate.performMenuAction(.connectivityTab) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Audio I/O") { delegate.performMenuAction(.audioTab) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Recording / Profiles") { delegate.performMenuAction(.profileTab) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Pan / EQ") { delegate.performMenuAction(.mixTab) }
                .keyboardShortcut("4", modifiers: .command)
        }
        CommandMenu("Profiles") {
            Button("New Profile") { delegate.performMenuAction(.newProfile) }
                .keyboardShortcut("n", modifiers: .command)
            Button("Save Profile") { delegate.performMenuAction(.saveProfile) }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save Profile As…") { delegate.performMenuAction(.saveProfileAs) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Open Profile…") { delegate.performMenuAction(.openProfile) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Quick Profile Switch…") { delegate.performMenuAction(.quickProfileSwitch) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Menu("Recent Profiles") {
                if delegate.recentMenuProfiles.isEmpty {
                    Button("No recent profiles") {}.disabled(true)
                } else {
                    ForEach(delegate.recentMenuProfiles) { profile in
                        Button(profile.title) { delegate.openRecentMenuProfile(profile.id) }
                    }
                }
            }
            Divider()
            Button("Rename Current Profile…") { delegate.performMenuAction(.renameProfile) }
            Button("Delete Current Profile…") { delegate.performMenuAction(.deleteProfile) }
            Button("Profile Passwords…") { delegate.performMenuAction(.profilePasswords) }
            Toggle("Lock Current Profile (Read Only)", isOn: Binding(
                get: { delegate.menuProfileReadOnly },
                set: { _ in delegate.performMenuAction(.toggleProfileLock) }))
        }
        CommandMenu("DAW Plugin") {
            Button(delegate.menuPluginsInstalled ? "Reinstall Plugins" : "Install Plugins") { delegate.performMenuAction(.installPlugins) }
            Button("Remove Plugins…") { delegate.performMenuAction(.removePlugins) }
                .disabled(!delegate.menuPluginsInstalled)
            Divider()
            Toggle("Apply Pan and EQ to Plugin Audio", isOn: Binding(
                get: { delegate.menuPluginShaping },
                set: { _ in delegate.performMenuAction(.togglePluginShaping) }))
        }
        CommandMenu("Record") {
            Button("Start or Stop Recording") { delegate.performMenuAction(.toggleRecording) }
                .keyboardShortcut("e", modifiers: .command)
            Button("Change Recordings Folder…") {
                delegate.performMenuAction(.changeRecordingsFolder)
            }
            Button("Open Recordings Folder") {
                delegate.performMenuAction(.openRecordingsFolder)
            }.keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Check for Updates…") { delegate.performMenuAction(.checkForUpdates) }
            Button("Help for Focused Control") { delegate.performMenuAction(.contextHelp) }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey)!)), modifiers: [])
            Button("Open RemSound Manual") { delegate.performMenuAction(.help) }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey)!)), modifiers: .shift)
            Button("RemSound Help") { delegate.performMenuAction(.help) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}

/// The Server and Metronome menus (2026-09-29): see JamController.
struct JamCommands: Commands {
    @ObservedObject var jam: JamController

    var body: some Commands {
        CommandMenu("Server") {
            Button(jam.serverMenuTitle) { jam.showServerWindow() }
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandMenu("Jamming") {
            Button(jam.selfMonitoringTitle) { jam.toggleSelfMonitoring() }
            Divider()
            Picker("Core Audio Buffer Size", selection: Binding(get: { jam.bufferFrames }, set: { jam.setBufferFrames($0) })) {
                ForEach(JamController.bufferChoices, id: \.self) { Text(jam.bufferLabel($0)).tag($0) }
            }
            Toggle("Keep in Time with Other Sound Cards", isOn: Binding(
                get: { jam.keepsInTime },
                set: { jam.setKeepsInTime($0) }))
            Divider()
            Button("Save the Last Minute of the Network") { jam.saveNetworkRecording() }
            Button("Choose Log Folder…") { jam.chooseLogFolder() }
        }
        CommandMenu("Metronome") {
            Button(jam.metronomeStartStopTitle) { jam.startStop() }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Toggle("Be the Master Metronome", isOn: Binding(
                get: { jam.isMaster },
                set: { jam.setMaster($0) }))
            Divider()
            Button("Tempo Up") { jam.tempo(1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Tempo Down") { jam.tempo(-1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Speak Metronome Status") { jam.speakMetronomeStatus() }
            Divider()
            Button("Metronome Settings…") { jam.showMetronomeSettings() }
                .keyboardShortcut(",", modifiers: [.command, .option])
        }
    }
}
