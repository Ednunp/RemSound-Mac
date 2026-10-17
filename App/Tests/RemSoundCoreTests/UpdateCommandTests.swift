import Darwin
import XCTest
@testable import RemSoundCore

final class UpdateCommandTests: XCTestCase {
    func testCapturesBothStreamsAndReportsNonzeroExit() throws {
        let output = try UpdateCommand.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf stdout; printf stderr >&2"], timeout: 2, maxOutput: 100)
        XCTAssertTrue(output.contains("stdout"))
        XCTAssertTrue(output.contains("stderr"))
        XCTAssertThrowsError(try UpdateCommand.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'fixture verification error' >&2; exit 7"], timeout: 2)) { error in
                XCTAssertTrue(error.localizedDescription.contains("exit 7"))
                XCTAssertTrue(error.localizedDescription.contains("fixture verification error"))
            }
    }
    func testTimeoutStopsExactProcessEvenWhenItIgnoresTermination() throws {
        try assertStopsProcess(code: "import time; time.sleep(60)", maxOutput: 100,
            expectedError: "timed out")
    }
    func testOutputLimitStopsExactProcessAndDoesNotRetainFlood() throws {
        try assertStopsProcess(code: "import os,time; os.write(1,b'x'*100000); time.sleep(60)",
            maxOutput: 100, expectedError: "too much output")
    }
    func testInvalidLimitsRefuseBeforeLaunch() {
        for timeout in [0.0, -1.0, .infinity, .nan] {
            XCTAssertThrowsError(try UpdateCommand.run(executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: [], timeout: timeout))
        }
        XCTAssertThrowsError(try UpdateCommand.run(executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: [], maxOutput: 0))
    }
    func testReportsFinalFailureAfterProgressOutput() {
        XCTAssertThrowsError(try UpdateCommand.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; print('progress '*400); print('final fixture failure'); sys.exit(9)"],
            timeout: 2)) { error in
                XCTAssertTrue(error.localizedDescription.contains("final fixture failure"))
                XCTAssertLessThan(error.localizedDescription.utf8.count, 2_100)
            }
    }
    private func assertStopsProcess(code: String, maxOutput: Int, expectedError: String) throws {
        let testRoot = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let pidFile = testRoot.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "import os,signal,sys; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(sys.argv[1],'w').write(str(os.getpid())); " + code
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try UpdateCommand.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, pidFile.path], timeout: 1, maxOutput: maxOutput)) { error in
                XCTAssertTrue(error.localizedDescription.contains(expectedError), error.localizedDescription)
            }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile)))
        XCTAssertEqual(kill(pid, 0), -1, "The runner must not leave its exact subprocess alive")
        XCTAssertEqual(errno, ESRCH)
    }
}
