import Foundation
import RemSoundCore
import RemSoundRuntime
import RemSoundSim

enum BootstrapSimulation {
    struct Output {
        let text: String
        let exitCode: Int
        let notice: String?
        init(text: String, exitCode: Int, notice: String? = nil) { self.text = text; self.exitCode = exitCode; self.notice = notice }
    }
    enum Failure: Error, LocalizedError {
        case invalidScope, publication
        var errorDescription: String? { "The replay request or private report publication could not be completed." }
    }
    static func output(for options: LaunchOptions,
        read: (URL) throws -> String = SimulationRecordingFile.read,
        publish: (String, URL) throws -> DiagnosticReportPublication = DiagnosticReportFile.publish) throws -> Output? {
        guard !options.help, let request = options.simulationReplay else { return nil }
        guard options.report == nil, options.selfTestPack == nil, options.selfTestOnly == nil,
            options.diagnosticLoggingEnabled == nil, options.controlRequest == nil,
            !options.headless, !options.checkAccessibility, options.startup.profileName == nil,
            options.startup.connectPeers.isEmpty, !options.startup.startMinimized else { throw Failure.invalidScope }
        let recording: String
        do { recording = try read(request.recording) } catch { throw ReplaySimulation.Failure.invalidRecording }
        let report = try NativeReplaySimulation.compare(recording, stream: request.stream,
            seconds: request.seconds, oneWayMs: request.oneWayMs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(report)
        guard bytes.count <= 16 * 1024 else { throw Failure.publication }
        let text = String(decoding: bytes, as: UTF8.self) + "\n"
        if let folder = request.outputDirectory {
            let receipt: DiagnosticReportPublication
            do { receipt = try publish(text, folder.appendingPathComponent("simulation-replay.json")) } catch { throw Failure.publication }
            guard receipt == .published else { return .init(text: text, exitCode: 1, notice: "Report location or cleanup is uncertain; no automatic retry.") }
        }
        return .init(text: text, exitCode: 0)
    }
}
