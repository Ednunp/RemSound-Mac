import XCTest
@testable import RemSoundJam

/// The peer details box (Windows BuildPeerDetailsText): its lines, order and words.
final class PeerDetailsTextTests: XCTestCase {
    private func facts(_ change: (inout PeerDetailsText.Facts) -> Void = { _ in }) -> PeerDetailsText.Facts {
        var f = PeerDetailsText.Facts(displayName: "Ed's studio", machineName: "ED_DT", address: "192.168.1.20",
                                      connectedFor: 125, healthy: true, pingMs: 22,
                                      streams: [(lane: "ASIO", codec: "Opus")], receiving: true, receivingYourAudio: true)
        change(&f)
        return f
    }

    func testAHealthyRenamedPeerReadsAsOnWindows() {
        XCTAssertEqual(PeerDetailsText.text(facts()), """
            Name: Ed's studio
            Machine name: ED_DT
            Address: 192.168.1.20
            Connected for: 2 minutes
            Link: healthy, ping 20 ms
            Sending: 1 stream on ASIO at 48000 Hz, Opus
            Receiving your audio: yes
            """)
    }

    func testAPeerAddedByAddressThatIsNotConnected() {
        let text = PeerDetailsText.text(facts {
            $0.displayName = "10.0.0.5"; $0.machineName = ""; $0.address = "10.0.0.5"; $0.connectedFor = nil
            $0.healthy = false; $0.streams = []; $0.receiving = false; $0.receivingYourAudio = false
        })
        XCTAssertEqual(text, """
            Machine name: (unknown — added by address)
            Address: 10.0.0.5
            Link: not connected
            Sending: turn on Receive audio to see the details
            Receiving your audio: no
            """)
    }

    func testDurationsReadAsWindowsSaysThem() {
        XCTAssertEqual(PeerDetailsText.duration(1), "1 second")
        XCTAssertEqual(PeerDetailsText.duration(59), "59 seconds")
        XCTAssertEqual(PeerDetailsText.duration(61), "1 minute")
        XCTAssertEqual(PeerDetailsText.duration(3_600 + 120), "1 hour 2 minutes")
    }
}
