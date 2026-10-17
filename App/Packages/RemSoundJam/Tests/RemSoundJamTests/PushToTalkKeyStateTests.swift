import Foundation
import XCTest
@testable import RemSoundJam

final class PushToTalkKeyStateTests: XCTestCase {
    func testDefaultHoldSpeaksOnlyWhileHeldBeforeAnyDoubleTap() {
        var state = PushToTalkKeyState()
        XCTAssertFalse(state.talking)
        XCTAssertTrue(state.press(atMilliseconds: 0))
        XCTAssertTrue(state.talking)
        XCTAssertTrue(state.release())
        XCTAssertFalse(state.talking)
    }

    func testRepeatedDownCannotBecomeADoubleTap() {
        var state = PushToTalkKeyState()
        XCTAssertTrue(state.press(atMilliseconds: 0))
        for time: Int64 in [1, 100, 300, 500] {
            XCTAssertFalse(state.press(atMilliseconds: time))
            XCTAssertTrue(state.talking)
        }
        XCTAssertTrue(state.release())
        XCTAssertFalse(state.talking)
        XCTAssertFalse(state.release())
    }

    func testHoldOnlyNeverLatchesWithRapidPresses() {
        var state = PushToTalkKeyState()
        state.configure(holdToSpeak: true, doubleTapToHold: false)
        for time: Int64 in [0, 100, 200, 300] {
            XCTAssertTrue(state.press(atMilliseconds: time))
            XCTAssertTrue(state.release())
            XCTAssertFalse(state.talking)
        }
    }

    func testNeitherOptionTogglesOnEachDistinctPress() {
        var state = PushToTalkKeyState()
        state.configure(holdToSpeak: false, doubleTapToHold: false)
        XCTAssertTrue(state.press(atMilliseconds: 0))
        XCTAssertTrue(state.talking)
        XCTAssertFalse(state.press(atMilliseconds: 1))
        XCTAssertFalse(state.release())
        XCTAssertTrue(state.talking)
        XCTAssertTrue(state.press(atMilliseconds: 100))
        XCTAssertFalse(state.talking)
        XCTAssertFalse(state.release())
    }

    func testSlowInclusiveBoundaryAndOneMillisecondOver() { checkBoundary(.slow, milliseconds: 900) }
    func testMediumInclusiveBoundaryAndOneMillisecondOver() { checkBoundary(.medium, milliseconds: 500) }
    func testFastInclusiveBoundaryAndOneMillisecondOver() { checkBoundary(.fast, milliseconds: 300) }

    private func checkBoundary(_ speed: PushToTalkDoubleTapSpeed, milliseconds: Int64,
                               file: StaticString = #filePath, line: UInt = #line) {
        for interval in [milliseconds - 1, milliseconds, milliseconds + 1] {
            var state = PushToTalkKeyState()
            state.configure(holdToSpeak: false, doubleTapToHold: true, speed: speed)
            XCTAssertFalse(state.press(atMilliseconds: 1_000), file: file, line: line)
            XCTAssertFalse(state.release(), file: file, line: line)
            let expected = interval <= milliseconds
            XCTAssertEqual(state.press(atMilliseconds: 1_000 + interval), expected, file: file, line: line)
            XCTAssertEqual(state.talking, expected, file: file, line: line)
            XCTAssertFalse(state.release(), file: file, line: line)
            XCTAssertEqual(state.talking, expected, file: file, line: line)
        }
    }

    func testOneTapReleasesDoubleOnlyLatchAndCannotStartAnotherPair() {
        var state = PushToTalkKeyState()
        state.configure(holdToSpeak: false, doubleTapToHold: true)
        state.press(atMilliseconds: 0); state.release()
        XCTAssertTrue(state.press(atMilliseconds: 100)); state.release()
        XCTAssertTrue(state.talking)
        XCTAssertTrue(state.press(atMilliseconds: 200))
        XCTAssertFalse(state.talking)
        XCTAssertFalse(state.release())
        XCTAssertFalse(state.press(atMilliseconds: 300), "The release tap starts no pending pair")
        state.release()
        XCTAssertTrue(state.press(atMilliseconds: 400))
        XCTAssertTrue(state.talking)
    }

    func testCombinedLatchReleasesAfterSingleTapComesUp() {
        var state = PushToTalkKeyState()
        state.press(atMilliseconds: 0); state.release()
        XCTAssertTrue(state.press(atMilliseconds: 100))
        XCTAssertFalse(state.release())
        XCTAssertTrue(state.talking)
        XCTAssertFalse(state.press(atMilliseconds: 200), "Hold still speaks during the release tap")
        XCTAssertTrue(state.release())
        XCTAssertFalse(state.talking)
        state.press(atMilliseconds: 300)
        XCTAssertTrue(state.release(), "A third quick press does not latch again")
        XCTAssertFalse(state.talking)
    }

    func testConfigureClearsLatchAndPendingPairAndUsesDefaultMedium() {
        var state = PushToTalkKeyState()
        state.configure(holdToSpeak: false, doubleTapToHold: true, speed: .slow)
        state.press(atMilliseconds: 0); state.release()
        state.press(atMilliseconds: 100); state.release()
        XCTAssertTrue(state.talking)
        state.configure(holdToSpeak: false, doubleTapToHold: true)
        XCTAssertFalse(state.talking)
        XCTAssertFalse(state.press(atMilliseconds: 200)); state.release()
        XCTAssertFalse(state.press(atMilliseconds: 800), "Default medium expires after 500 ms")
        state.release()
        XCTAssertTrue(state.press(atMilliseconds: 1_300), "Inclusive medium limit survives configure")
    }

    func testResetClearsHeldToggleAndPendingPairWithoutChangingRules() {
        var state = PushToTalkKeyState()
        state.press(atMilliseconds: 0)
        state.reset()
        XCTAssertFalse(state.talking)
        XCTAssertFalse(state.release())
        state.configure(holdToSpeak: false, doubleTapToHold: false)
        state.press(atMilliseconds: 10)
        state.reset()
        XCTAssertFalse(state.talking)
        XCTAssertTrue(state.press(atMilliseconds: 20), "Toggle rule is retained")
        state.configure(holdToSpeak: false, doubleTapToHold: true)
        state.press(atMilliseconds: 30); state.release()
        state.reset()
        XCTAssertFalse(state.press(atMilliseconds: 40), "Reset discards pending tap")
    }

    func testLongHoldMeasuresTheNextTapFromPressRatherThanRelease() {
        var state = PushToTalkKeyState()
        state.press(atMilliseconds: 0); state.release()
        state.press(atMilliseconds: 10_000)
        XCTAssertTrue(state.release())
        XCTAssertFalse(state.talking)
    }

    func testRepeatedPressDoesNotExtendPendingPairClock() {
        var state = PushToTalkKeyState()
        state.configure(holdToSpeak: false, doubleTapToHold: true)
        state.press(atMilliseconds: 0)
        XCTAssertFalse(state.press(atMilliseconds: 499))
        state.release()
        XCTAssertFalse(state.press(atMilliseconds: 600))
        XCTAssertFalse(state.talking)
    }

    func testBackwardsClockDoesNotLatchAndNextValidPairCanRecover() {
        var state = PushToTalkKeyState()
        state.configure(holdToSpeak: false, doubleTapToHold: true)
        state.press(atMilliseconds: 1_000); state.release()
        XCTAssertFalse(state.press(atMilliseconds: 999)); state.release()
        XCTAssertTrue(state.press(atMilliseconds: 1_000))
    }

    func testOverflowingElapsedTimeDoesNotLatchOrTrap() {
        var state = PushToTalkKeyState()
        state.configure(holdToSpeak: false, doubleTapToHold: true)
        state.press(atMilliseconds: .min); state.release()
        XCTAssertFalse(state.press(atMilliseconds: .max)); state.release()
        XCTAssertFalse(state.press(atMilliseconds: .min)); state.release()
        XCTAssertTrue(state.press(atMilliseconds: Int64.min + 1))
    }

    func testRepresentablePairsNearBothClockExtremes() {
        for start in [Int64.min, Int64.max - 500] {
            var state = PushToTalkKeyState()
            state.configure(holdToSpeak: false, doubleTapToHold: true)
            state.press(atMilliseconds: start); state.release()
            XCTAssertTrue(state.press(atMilliseconds: start + 500))
        }
    }

    func testStrayReleaseChangesNeitherTalkingNorPendingPair() {
        var state = PushToTalkKeyState()
        state.configure(holdToSpeak: false, doubleTapToHold: true)
        XCTAssertFalse(state.release())
        state.press(atMilliseconds: 0); state.release()
        XCTAssertFalse(state.release())
        XCTAssertTrue(state.press(atMilliseconds: 100))
    }

    func testValueCopiesHaveIndependentHeldAndLatchedState() {
        var original = PushToTalkKeyState()
        original.press(atMilliseconds: 0); original.release()
        var copy = original
        copy.press(atMilliseconds: 100); copy.release()
        XCTAssertTrue(copy.talking)
        XCTAssertFalse(original.talking)
        original.reset()
        XCTAssertTrue(copy.talking)
    }

    func testSpeedRawValuesAndDurationsMatchWindowsContract() throws {
        XCTAssertEqual(PushToTalkDoubleTapSpeed.allCases.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(PushToTalkDoubleTapSpeed.allCases.map(\.maximumIntervalMilliseconds), [900, 500, 300])
        for speed in PushToTalkDoubleTapSpeed.allCases {
            XCTAssertEqual(try JSONDecoder().decode(PushToTalkDoubleTapSpeed.self,
                                                   from: JSONEncoder().encode(speed)), speed)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(PushToTalkDoubleTapSpeed.self, from: Data("3".utf8)))
    }
}
