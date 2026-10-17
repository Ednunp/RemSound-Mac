import Foundation
import XCTest

@testable import RemSoundJam

/// Remote volume and mute: the plaintext Windows pins, and the receiver's refusals.
final class RemoteControlTests: XCTestCase {
    let when: Int64 = 1_790_000_000

    func testThePlaintextIsTheOneWindowsPins() {
        // SelfTest.KnownAnswers.cs: VolumeDown, a step of -3, sent at 1790000000 - "01 FD 803BB16A00000000".
        XCTAssertEqual(RemoteControl.plaintext(.volumeDown, delta: -3, unixSeconds: when),
                       [0x01, 0xFD, 0x80, 0x3B, 0xB1, 0x6A, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(RemoteControl.plaintext(.volumeUp, delta: 5, unixSeconds: when),
                       [0x00, 0x05, 0x80, 0x3B, 0xB1, 0x6A, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(RemoteControl.plaintext(.systemMuteToggle, delta: 0, unixSeconds: when)[0], 5)
        let back = RemoteControl.parse([0x01, 0xFD, 0x80, 0x3B, 0xB1, 0x6A, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(back?.kind, .volumeDown)
        XCTAssertEqual(back?.delta, -3)
        XCTAssertEqual(back?.unixSeconds, when)
        XCTAssertEqual(RemoteControl.sealedBytes, RemoteControl.plainBytes + 28, "nonce 12 and tag 16 around the plaintext")
        XCTAssertEqual(RemoteControl.streamID, 0xFFFE)
    }

    func testAKindNobodySendsOrAWrongSizeIsNotACommand() {
        XCTAssertNil(RemoteControl.parse([6, 0, 0, 0, 0, 0, 0, 0, 0, 0]), "kinds are 0 to 5")
        XCTAssertNil(RemoteControl.parse([0, 5]), "the old two-byte form")
        XCTAssertNil(RemoteControl.parse([0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0]), "one byte too many")
    }

    func testTheVolumeMovesByTheStepTheKindSaysWhateverItsSignAndStaysInRange() {
        XCTAssertEqual(RemoteControl.nudged(volume: 80, kind: .volumeUp, delta: 5), 85)
        XCTAssertEqual(RemoteControl.nudged(volume: 80, kind: .volumeUp, delta: -5), 85, "the kind sets the direction")
        XCTAssertEqual(RemoteControl.nudged(volume: 80, kind: .volumeDown, delta: 5), 75)
        XCTAssertEqual(RemoteControl.nudged(volume: 98, kind: .volumeUp, delta: 5), 100)
        XCTAssertEqual(RemoteControl.nudged(volume: 3, kind: .volumeDown, delta: -5), 0)
        XCTAssertEqual(RemoteControl.nudged(volume: 40, kind: .muteToggle, delta: 5), 40)
        XCTAssertEqual(RemoteControl.nudged(volume: 50, kind: .volumeDown, delta: -128), 0, "the largest step there is")
    }

    func testWhatEachKindCarriesAndWhatTheSoundIsMultipliedBy() {
        XCTAssertEqual(RemoteControl.Kind.allCases.map { RemoteControl.delta(for: $0) }, [5, -5, 0, 0, 0, 0],
                       "the Windows hotkeys: +5, -5, and no step for the rest")
        XCTAssertEqual(RemoteControl.listeningGain(volume: 100, muted: false), 1)
        XCTAssertEqual(RemoteControl.listeningGain(volume: 35, muted: false), 0.35, accuracy: 1e-6)
        XCTAssertEqual(RemoteControl.listeningGain(volume: 80, muted: true), 0, "muted is silent whatever the volume")
        XCTAssertEqual(RemoteControl.listeningGain(volume: 140, muted: false), 1)
        XCTAssertEqual(RemoteControl.listeningGain(volume: -3, muted: false), 0)
    }

    func testTheComputersVolumeMovesASixteenthAStepAndReadsAsWindowsWritesIt() {
        XCTAssertEqual(RemoteControl.steppedSystemVolume(0.5, up: true), 0.5625)
        XCTAssertEqual(RemoteControl.steppedSystemVolume(0.5, up: false), 0.4375)
        XCTAssertEqual(RemoteControl.steppedSystemVolume(0.98, up: true), 1)
        XCTAssertEqual(RemoteControl.steppedSystemVolume(0.02, up: false), 0)
        XCTAssertEqual(RemoteControl.describeSystem((0.5625, false)), "56%", "truncated, as Windows' (int) cast")
        XCTAssertEqual(RemoteControl.describeSystem((1, true)), "100% MUTED")
        XCTAssertEqual(RemoteControl.describeSystem(nil), "?")
    }

    func sealed(nonce: UInt8) -> [UInt8] { [nonce, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] + [UInt8](repeating: 0xAA, count: 26) }

    func testAFreshCommandIsAcceptedOnceAndNeverAgain() {
        var guardian = ControlReceiveGuard()
        let plain = RemoteControl.plaintext(.volumeUp, delta: 5, unixSeconds: when)
        XCTAssertEqual(guardian.check(sealed: sealed(nonce: 1), plain: plain, now: TimeInterval(when)), .accepted(.volumeUp, 5))
        XCTAssertEqual(guardian.check(sealed: sealed(nonce: 1), plain: plain, now: TimeInterval(when) + 1), .replay,
                       "the same packet again is a replay")
        XCTAssertEqual(guardian.check(sealed: sealed(nonce: 2), plain: plain, now: TimeInterval(when) + 1), .accepted(.volumeUp, 5),
                       "a new nonce is a new command")
    }

    func testTenMinutesEitherWayAndNoMore() {
        var guardian = ControlReceiveGuard()
        let plain = RemoteControl.plaintext(.muteToggle, delta: 0, unixSeconds: when)
        XCTAssertEqual(guardian.check(sealed: sealed(nonce: 1), plain: plain, now: TimeInterval(when) + 600), .accepted(.muteToggle, 0),
                       "exactly ten minutes old is still accepted")
        XCTAssertEqual(guardian.check(sealed: sealed(nonce: 2), plain: plain, now: TimeInterval(when) - 600), .accepted(.muteToggle, 0),
                       "and ten minutes ahead")
        if case .stale = guardian.check(sealed: sealed(nonce: 3), plain: plain, now: TimeInterval(when) + 3600) {} else { XCTFail("an hour old is stale") }
        if case .stale = guardian.check(sealed: sealed(nonce: 4), plain: plain, now: TimeInterval(when) - 3600) {} else { XCTFail("an hour ahead is stale") }
        XCTAssertEqual(guardian.check(sealed: sealed(nonce: 5), plain: plain, now: TimeInterval(when) + 300), .accepted(.muteToggle, 0))
        XCTAssertEqual(guardian.check(sealed: sealed(nonce: 6), plain: plain, now: TimeInterval(when) + 601), .stale(minutes: 601.0 / 60),
                       "a second past ten minutes is stale")
        XCTAssertEqual(guardian.check(sealed: sealed(nonce: 7), plain: plain, now: TimeInterval(when) - 601), .stale(minutes: 601.0 / 60))
        XCTAssertEqual(ControlReceiveGuard.Verdict.stale(minutes: 11).reason, "stale (sent 11.0 min from now, window 10 min)",
                       "Windows' words, the minutes unsigned")
    }

    func testWhatWouldNotOpenOrIsTheWrongSizeIsRefused() {
        var guardian = ControlReceiveGuard()
        let plain = RemoteControl.plaintext(.volumeUp, delta: 5, unixSeconds: when)
        XCTAssertEqual(guardian.check(sealed: sealed(nonce: 1), plain: nil, now: TimeInterval(when)), .notSealed,
                       "a wrong password or a tampered packet does not open")
        XCTAssertEqual(guardian.check(sealed: Array(sealed(nonce: 1).prefix(37)), plain: plain, now: TimeInterval(when)), .notSealed)
        XCTAssertEqual(guardian.check(sealed: sealed(nonce: 1) + [0], plain: plain, now: TimeInterval(when)), .notSealed)
        XCTAssertEqual(guardian.remembered, 0, "nothing refused is remembered")
        XCTAssertEqual(ControlReceiveGuard.Verdict.notSealed.reason, "not-sealed (wrong password, tampered, or a pre-5.6 peer)")
    }

    func testThreeHundredCommandsInARowAreAllAcceptedAndTheMemoryIsTrimmedOfTheOld() {
        var guardian = ControlReceiveGuard()
        var t = TimeInterval(when)
        for i in 0..<300 {
            var s = sealed(nonce: 0)
            s[0] = UInt8(i & 0xFF)
            s[1] = UInt8(i >> 8)
            let plain = RemoteControl.plaintext(.volumeUp, delta: 5, unixSeconds: Int64(t))
            XCTAssertEqual(guardian.check(sealed: s, plain: plain, now: t), .accepted(.volumeUp, 5), "command \(i)")
            t += 10   // ten seconds apart: fifty minutes in all
        }
        XCTAssertLessThan(guardian.remembered, 300, "what is over twenty minutes old is forgotten once 256 are held")
    }
}

/// Windows' ECHO AND FLOODS: a thousand refused is said once, not a thousand times.
final class RefusalCounterTests: XCTestCase {
    func testAFloodFromStrangersIsCountedAndSaidOnceAMinute() {
        var refused = RefusalCounter()
        var said: [Int] = []
        for i in 0..<500 { if let n = refused.note(now: 1000 + Double(i) * 0.01) { said.append(n) } }
        XCTAssertEqual(said, [1], "the first said at once, the other 499 only counted")
        XCTAssertEqual(refused.count, 500)
        XCTAssertEqual(refused.note(now: 1061), 501, "a minute on, said again with the count so far")
        XCTAssertNil(refused.note(now: 1062))
    }
}
