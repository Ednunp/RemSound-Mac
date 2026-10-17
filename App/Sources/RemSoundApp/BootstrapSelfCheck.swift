import Foundation
@_spi(NativeProductChecks) import RemSoundCore
import RemSoundRuntime

enum BootstrapSelfCheck {
    struct Output: Equatable { let text: String; let exitCode: Int }
    enum Failure: Error { case invalidReport, tooLarge }
    private static let maximumBytes = 16 * 1024
    static func output(for options: LaunchOptions, run: (Double) -> SelfCheckReport = ProductSelfCheck.run, nativeProfileLogging: (() -> (assertions: Int, failures: [String])?)? = nil, nativeControlSpecifications: (() -> (assertions: Int, failures: [String])?)? = nil, nativeDialogs: ((Bool) -> (assertions: Int, failures: [String])?)? = nil, nativeEventClaims: (() -> (assertions: Int, failures: [String])?)? = nil, nativeAudioAxis: (() -> (assertions: Int, failures: [String])?)? = nil, nativeContextHelp: (() -> (assertions: Int, failures: [String])?)? = nil) throws -> Output? {
        guard options.report == .selfCheck, !options.help else { return nil }
        guard (1...LaunchOptions.maximumSelfCheckSeconds).contains(options.selfCheckSeconds) else { throw RuntimeConfigurationError.invalidSelfCheckOptions }
        if options.configurationDirectory != nil {
            _ = try RuntimeConfiguration.profilesDirectoryForListing(root:options.configurationDirectory,defaultDirectory:ProfileStore.defaultDirectory)
        }
        if let raw=options.selfTestPack {
            guard let pack=ProductTestPack.Pack(rawValue:raw) else { throw RuntimeConfigurationError.invalidSelfCheckOptions }
            let report: ProductTestPack.Report
            if nativeProfileLogging != nil || nativeControlSpecifications != nil || nativeDialogs != nil || nativeEventClaims != nil || nativeAudioAxis != nil || nativeContextHelp != nil {
                report=ProductTestPack.run(pack:pack,only:options.selfTestOnly,budget:Double(options.selfCheckSeconds),nativeProfileLogging:nativeProfileLogging ?? { nil },nativeControlSpecifications:nativeControlSpecifications,nativeDialogs:nativeDialogs,nativeEventClaims:nativeEventClaims,nativeAudioAxis:nativeAudioAxis,nativeContextHelp:nativeContextHelp)
            } else { report=ProductTestPack.run(pack:pack,only:options.selfTestOnly,budget:Double(options.selfCheckSeconds)) }
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let bytes=try encoder.encode(report)
            guard bytes.count <= 256*1024 else { throw Failure.tooLarge }
            return .init(text:String(decoding:bytes,as:UTF8.self)+"\n",exitCode:report.exitCode)
        }
        guard options.selfTestOnly == nil else { throw RuntimeConfigurationError.invalidSelfCheckOptions }
        let report=run(Double(options.selfCheckSeconds))
        guard report.isValid else { throw Failure.invalidReport }
        var lines:[String]=[],bytes=0
        func append(_ value:String) throws {
            let count=value.utf8.count+1
            guard count <= maximumBytes-bytes else { throw Failure.tooLarge }
            bytes += count;lines.append(value)
        }
        func label(_ id:SelfCheckReport.ID) -> String {
            switch id {
            case .wire: return "Packet framing and rejection"
            case .format: return "Stream format parsing"
            case .encryption: return "Password-derived encryption and rejection"
            case .ring: return "In-memory audio ring"
            case .opus: return "Synthetic Opus-live codec"
            }
        }
        try append("RemSound self-check (hardware-free, partial scope)")
        try append("Budget: \(options.selfCheckSeconds) seconds maximum, cooperative; not a capture duration or hard wall-time guarantee.")
        for step in report.steps {
            let status:String
            switch step.status { case .passed: status="PASS";case .failed: status="FAIL";case .notRun: status="NOT RUN" }
            try append("\(status): \(label(step.id)); \(step.assertions) completed assertions.")
        }
        try append("Termination: "+report.termination.rawValue)
        for gap in report.unverified { try append("UNVERIFIED: "+gap.rawValue) }
        let passed=report.steps.filter { $0.status == .passed }.count
        let failed=report.steps.filter { $0.status == .failed }.count
        let notRun=report.steps.filter { $0.status == .notRun }.count
        try append("Summary: \(passed) passed, \(failed) failed, \(notRun) not run.")
        try append(report.exitCode == 1 ? "RESULT: FAIL (exit 1)." : "RESULT: PARTIAL (exit 3); full application acceptance remains unverified.")
        try append("No runtime, physical devices, sockets, credential stores, settings, windows or timers were started by these checks.")
        return .init(text:lines.joined(separator:"\n")+"\n",exitCode:report.exitCode)
    }
}
