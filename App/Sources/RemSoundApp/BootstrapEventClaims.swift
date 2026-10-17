import Foundation
import AppKit
import RemSoundCore
import RemSoundRuntime

enum BootstrapEventClaims {
    static let permission = "REMSOUND_TEST_NATIVE_EVENT_CLAIMS"
    static func accepts(root: URL?, environment: [String: String]) -> Bool {
        BootstrapProfileLogging.accepts(root: root, environment: environment, permission: permission)
    }
    static func run(for options: LaunchOptions) -> (assertions: Int, failures: [String])? {
        let environment = ProcessInfo.processInfo.environment
        guard accepts(root: options.configurationDirectory, environment: environment), Thread.isMainThread,
            AppRuntime.configuration == nil else { return nil }
        do {
            let source = try BootstrapDialogAudit.sources(environment: environment, includeNativeSources: true)
            return MainActor.assumeIsolated {
                guard NSApp == nil else { return (1, ["events.native.native-application-already-created"]) }
                var result = NativeEventClaims.inspect(sources: source, stepNames: ProductTestPack.names)
                result.assertions += 1
                if AppRuntime.configuration != nil || NSApp != nil { result.failures.append("events.native.unexpected-runtime-or-window-startup") }
                return result
            }
        } catch { return (1, ["events.native.isolated-source-refused"]) }
    }
}
