import Foundation
import RemSoundRuntime

extension ProductTestPack {
    static let logsPerProfile="LOGS PER PROFILE: each profile logs by its own choice, this computer's setting following; never chosen follows the computer; new profiles off"
    static func checkProfileLogging(native: (() -> (assertions: Int, failures: [String])?)? = nil) -> Step {
        var count=0,failures=[String]()
        func require(_ value:Bool,_ code:String) {count += 1;if !value {failures.append(code)}}
        let parent=ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"].map {URL(fileURLWithPath:$0)}
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root=parent.appendingPathComponent("profile-log-check-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        do {
            let config=try RuntimeConfiguration(options:LaunchOptions.parse(["--config-dir",root.path]))
            let session=Session(configuration:config),store=ProfileStore(directory:config.profilesDirectory)
            var profile=ConnectionProfile(title:"Product logging fixture",displayName:"Mac",manualPeerAddress:"",selectedPeerAddresses:[],sendInput:false,receiveAudio:false,allowPlugins:false,reconnectOnOpen:false)
            require(profile.enableLogs == nil,"logs.blank-inherits")
            for choice in [false,true] {
                profile.enableLogs=choice;try store.save(profile)
                require(try store.load(id:profile.id).enableLogs == choice,"logs.profile-file")
                require(session.applyDiagnosticLogging(profileChoice:choice),"logs.explicit-admitted")
                require(session.diagnosticLoggingEnabled == choice,"logs.actual-session-gate")
                require(DiagnosticLoggingPreferences.enabled(in:config.settings) == choice,"logs.computer-follows")
            }
            let file=config.logsDirectory.appendingPathComponent("Latest.log")
            session.note("product logging enabled");require(session.diagnosticLoggingEnabled,"logs.note-barrier")
            let bytes=try Data(contentsOf:file)
            require(String(decoding:bytes,as:UTF8.self).contains("product logging enabled"),"logs.actual-write")
            require(session.applyDiagnosticLogging(profileChoice:false),"logs.disable")
            session.note("must stay suppressed");require(!session.diagnosticLoggingEnabled,"logs.disable-barrier")
            require(try Data(contentsOf:file) == bytes,"logs.no-write-after-off")
            for choice in [true,false] {
                require(DiagnosticLoggingPreferences.setEnabled(choice,in:config.settings),"logs.computer-choice")
                let prior=try Data(contentsOf:root.appendingPathComponent("settings.plist"))
                require(session.applyDiagnosticLogging(profileChoice:nil) && session.diagnosticLoggingEnabled == choice,"logs.inherit-effective")
                require(try Data(contentsOf:root.appendingPathComponent("settings.plist")) == prior,"logs.inherit-does-not-write")
            }
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(profile)) as! [String:Any]
            object.removeValue(forKey:"enableLogs");object["LoggingEnabled"]=true
            let old=try JSONDecoder().decode(ConnectionProfile.self,from:JSONSerialization.data(withJSONObject:object))
            require(old.enableLogs == nil,"logs.retired-key-ignored")
        } catch {failures.append("profile-logging-isolated-operation-failed")}
        guard failures.isEmpty else { return .init(name: logsPerProfile, status: "FAIL", assertions: count, failures: failures) }
        guard let observed = native?() else {
            return .init(name: logsPerProfile, status: "UNVERIFIED", assertions: count,
                failures: ["native-preferences-New-Open-Cancel-acceptance-not-in-named-runner"])
        }
        guard (1...128).contains(observed.assertions), observed.failures.count <= 128,
            observed.failures.allSatisfy({ $0.hasPrefix("logs.native.") && $0.utf8.count <= 128 && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 } }) else {
            return .init(name: logsPerProfile, status: "FAIL", assertions: count, failures: ["logs.native.invalid-receipt"])
        }
        return .init(name: logsPerProfile, status: observed.failures.isEmpty ? "PASS" : "FAIL",
            assertions: count + observed.assertions, failures: observed.failures)
    }
}
