import Foundation
import RemSoundRuntime
import XCTest
@testable import RemSoundCore

final class DiagnosticLoggingSessionTests: XCTestCase {
    private func configuration(_ enabled:Bool?) throws -> RuntimeConfiguration {
        let root=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        let store=try RuntimeConfiguration.settingsForStandaloneCommand(root:root)
        if let enabled { XCTAssertTrue(DiagnosticLoggingPreferences.setEnabled(enabled,in:store)) }
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return try RuntimeConfiguration(options:LaunchOptions.parse(["--config-dir",root.path]))
    }
    func testOffSuppressesActualStoppedSessionNoteWithoutOpeningAudioOrSocket() throws {
        let config=try configuration(false),session=Session(configuration:config)
        session.note("bounded fixture note")
        XCTAssertEqual(session.testPorts.audio,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:config.logsDirectory.appendingPathComponent("Latest.log").path))
    }
    func testOnAndMissingChoicePreserveActualStoppedSessionStateLog() throws {
        for choice in [Bool?.none, Bool?.some(true)] {
            let config=try configuration(choice),session=Session(configuration:config)
            session.note("bounded fixture note")
            XCTAssertEqual(session.testPorts.audio,0)
            let text=try String(contentsOf:config.logsDirectory.appendingPathComponent("Latest.log"))
            XCTAssertTrue(text.contains("bounded fixture note"))
        }
    }
    func testOffRefusesDetailedLoggerBeforePruningOwnedSentinel() throws {
        let config=try configuration(false),session=Session(configuration:config)
        let sentinel=config.logsDirectory.appendingPathComponent("RemSound-Mac-RemSoundMac-old.log")
        try Data("retained".utf8).write(to:sentinel)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1)],ofItemAtPath:sentinel.path)
        session.openDetailedLog()
        XCTAssertEqual(try? Data(contentsOf:sentinel),Data("retained".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:config.logsDirectory.path),["RemSound-Mac-RemSoundMac-old.log"])
    }
}
