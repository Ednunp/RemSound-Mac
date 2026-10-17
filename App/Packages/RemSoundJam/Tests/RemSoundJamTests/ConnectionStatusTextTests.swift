import XCTest
@testable import RemSoundJam

/// The Connection status box (Windows MainForm's status readout).
final class ConnectionStatusTextTests: XCTestCase {
    func testAConnectedSessionReadsAsOnWindows() {
        let f = ConnectionStatusText.Facts(connected: [(name: "ED_DT", link: "ping 20 ms, total latency about 45 ms")],
            differentPassword: ["Studio"], uptime: 125, extras: ["Metronome: playing 120 bpm 4/4"],
            receivingKBs: 48.04, sendingKBs: 47.96, receivedBytes: 981_000_000, sentBytes: 5_000_000_000,
            cpuPercent: 3.4, memoryBytes: 150 * 1_048_576)
        XCTAssertEqual(ConnectionStatusText.text(f), """
            Connected to 1 peer.
              ED_DT: ping 20 ms, total latency about 45 ms
              Studio: a different password, not connected
            Uptime: 2 minutes 5 seconds.
            Metronome: playing 120 bpm 4/4.
            Receiving 48.0 kB/s; sending 48.0 kB/s.
            Total received 935.6 MB; sent 4.7 GB.
            CPU usage 3% and memory 150.0 MB.
            """)
    }

    func testNobodyConnected() {
        let f = ConnectionStatusText.Facts(connected: [], differentPassword: [], uptime: nil, extras: [], receivingKBs: 0,
            sendingKBs: 0, receivedBytes: 0, sentBytes: 0, cpuPercent: 0.2, memoryBytes: 90 * 1_048_576)
        XCTAssertTrue(ConnectionStatusText.text(f).hasPrefix("Not connected to any peer.\nUptime: 0 seconds.\n"))
    }

    func testCpuIsAShareOfTheWholeMachineAndUptimeWords() {
        XCTAssertEqual(ConnectionStatusText.cpuPercent(cpuSecondsDelta: 0.8, elapsed: 1, cores: 8), 10, accuracy: 1e-9)
        XCTAssertEqual(ConnectionStatusText.uptime(3_660), "1 hour 1 minute")
        XCTAssertEqual(ConnectionStatusText.uptime(1), "1 second")
    }
}
