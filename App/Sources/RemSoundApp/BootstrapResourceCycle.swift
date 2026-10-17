import Foundation
import RemSoundCore
import RemSoundRuntime
enum BootstrapResourceCycle {
    struct Output:Equatable { let text:String,exitCode:Int }
    enum Failure:Error { case invalidReport,tooLarge }
    private static let maximumBytes=16*1024
    static func output(for options:LaunchOptions,run:(Int)->ResourceCycleReport=ProductResourceCycle.run)throws->Output? {
        guard options.report == .resourceCycle,!options.help else {return nil}
        guard LaunchOptions.resourceCycleSecondsRange.contains(options.resourceCycleSeconds) else {throw RuntimeConfigurationError.invalidResourceCycleOptions}
        if options.configurationDirectory != nil {
            _=try RuntimeConfiguration.profilesDirectoryForListing(root:options.configurationDirectory,defaultDirectory:ProfileStore.defaultDirectory)
        }
        let report=run(options.resourceCycleSeconds)
        guard report.isValid,report.requestedSeconds==options.resourceCycleSeconds else {throw Failure.invalidReport}
        var lines:[String]=[],bytes=0
        func append(_ value:String)throws {
            let count=value.utf8.count+1;guard count<=maximumBytes-bytes else {throw Failure.tooLarge}
            bytes += count;lines.append(value)
        }
        func unsigned<T>(_ value:T?)->String {value.map {String(describing:$0)} ?? "UNAVAILABLE"}
        func signed<T:FixedWidthInteger>(_ value:T?)->String {
            guard let value else {return "UNAVAILABLE"}
            return value==0 ? "0":(value<0 ? "minus ":"plus ")+String(describing:value.magnitude)
        }
        try append("RemSound resource-cycle check (hardware-free, partial scope)")
        try append("Budget: \(report.requestedSeconds) seconds for three memory-work cycles, cooperative; not a physical capture duration or hard wall-time guarantee.")
        try append("Provenance: "+report.provenance.rawValue)
        try append("Each cycle stops at 4096 retired work items; an early cap is incomplete. Native calls cannot be interrupted mid-call.")
        for observation in report.observations {
            try append("Observation \(observation.cycle) at \(observation.elapsed) seconds: resident bytes \(unsigned(observation.snapshot.residentBytes)); threads \(unsigned(observation.snapshot.threads)); descriptors \(unsigned(observation.snapshot.descriptors)); cumulative CPU seconds \(unsigned(observation.snapshot.cpuSeconds)).")
            if observation.collectionFailed {try append("Collection UNAVAILABLE.")}
        }
        for cycle in report.completed {try append("Cycle \(cycle.index): \(cycle.items) retired work items; \(cycle.elapsed) seconds.")}
        let growth=report.growth
        try append("Final minus baseline: resident bytes \(signed(growth.residentBytes)); threads \(signed(growth.threads)); descriptors \(signed(growth.descriptors)); CPU seconds \(unsigned(growth.cpuSeconds)).")
        try append("Termination: "+report.termination.rawValue)
        try append("UNVERIFIED: Physical audio, Session/network/router, keyboard/spoken output, storage/package assets and long-running application stability.")
        try append("Observations are non-atomic. Missing/changing counters remain unavailable; these deltas are not a peak, leak or optimisation verdict. No Windows GC or handle threshold is applied.")
        try append(report.exitCode==1 ? "RESULT: FAIL (exit 1).":"RESULT: PARTIAL (exit 3); full application performance acceptance remains unverified.")
        try append("No runtime, physical device, socket, credential store, settings, window or timer was started by this workload.")
        return .init(text:lines.joined(separator:"\n")+"\n",exitCode:report.exitCode)
    }
}
