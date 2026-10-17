import Foundation
import XCTest
@testable import RemSoundRuntime

final class PluginHelpRuntimeStateTests: XCTestCase {
    func testSilentMarkerIsOwnedAndRemovedWithoutTouchingCueChoices() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("plugin-help-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SettingsStore(file: root.appendingPathComponent("settings.plist"))
        store.set("help open 3.wav", forKey: "cueSound.helpOpen")
        PluginHelpRuntimeState.begin(settings: store, silent: true, processID: 123)
        XCTAssertTrue(store.bool(forKey: PluginHelpRuntimeState.preferencesAvailableKey))
        XCTAssertEqual(store.integer(forKey: PluginHelpRuntimeState.silentProcessKey), 123)
        PluginHelpRuntimeState.end(settings: store, processID: 456)
        XCTAssertEqual(store.integer(forKey: PluginHelpRuntimeState.silentProcessKey), 123)
        PluginHelpRuntimeState.end(settings: store, processID: 123)
        XCTAssertNil(store.object(forKey: PluginHelpRuntimeState.silentProcessKey))
        XCTAssertEqual(store.string(forKey: "cueSound.helpOpen"), "help open 3.wav")
        XCTAssertTrue(store.bool(forKey: PluginHelpRuntimeState.preferencesAvailableKey), "Help choices remain readable after quitting")
        PluginHelpRuntimeState.begin(settings: store, silent: true, processID: 789)
        PluginHelpRuntimeState.begin(settings: store, silent: false, processID: 987)
        XCTAssertNil(store.object(forKey: PluginHelpRuntimeState.silentProcessKey))
    }
}
