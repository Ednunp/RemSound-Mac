#if DEBUG
import Foundation
import XCTest
@testable import RemSoundApp

final class HeadlessPeerMoveCheckPolicyTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/isolated-tests/peer-move-fixture")
    private let environment = ["REMSOUND_TEST_PEER_MOVE_CHECK": "1", "REMSOUND_TEST_ROOT": "/isolated-tests"]
    func testExplicitSilentHeadlessChildConfigurationIsAccepted() {
        XCTAssertTrue(HeadlessPeerMoveCheckPolicy.accepts(root: root, headless: true, silent: true, environment: environment))
    }
    func testNormalRuntimeIsRejectedWithoutReadingNormalSettings() {
        XCTAssertFalse(HeadlessPeerMoveCheckPolicy.accepts(root: nil, headless: true, silent: true, environment: environment))
    }
    func testVisibleOrAudibleRuntimeIsRejected() {
        XCTAssertFalse(HeadlessPeerMoveCheckPolicy.accepts(root: root, headless: false, silent: true, environment: environment))
        XCTAssertFalse(HeadlessPeerMoveCheckPolicy.accepts(root: root, headless: true, silent: false, environment: environment))
    }
    func testBothExactOptInAndTestRootAreRequired() {
        for env in [[:], ["REMSOUND_TEST_ROOT": "/isolated-tests"], ["REMSOUND_TEST_PEER_MOVE_CHECK": "1"],
                    ["REMSOUND_TEST_PEER_MOVE_CHECK": "true", "REMSOUND_TEST_ROOT": "/isolated-tests"]] {
            XCTAssertFalse(HeadlessPeerMoveCheckPolicy.accepts(root: root, headless: true, silent: true, environment: env))
        }
    }
    func testTestRootMustBeAbsoluteAndCannotBeFilesystemRoot() {
        for path in ["", "relative", "/"] {
            var env = environment; env["REMSOUND_TEST_ROOT"] = path
            XCTAssertFalse(HeadlessPeerMoveCheckPolicy.accepts(root: root, headless: true, silent: true, environment: env))
        }
    }
    func testSiblingPrefixParentAndRootItselfAreRejected() {
        for path in ["/isolated-tests-extra/fixture", "/elsewhere/fixture", "/isolated-tests", "/isolated-tests/../outside"] {
            XCTAssertFalse(HeadlessPeerMoveCheckPolicy.accepts(root: URL(fileURLWithPath: path), headless: true, silent: true, environment: environment))
        }
    }
    func testStandardizedChildPathKeepsItsBoundary() {
        XCTAssertTrue(HeadlessPeerMoveCheckPolicy.accepts(root: URL(fileURLWithPath: "/isolated-tests/nested/../fixture"),
            headless: true, silent: true, environment: environment))
    }
}
#endif
