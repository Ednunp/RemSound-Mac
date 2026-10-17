import AppKit
import XCTest
@testable import RemSoundApp

@MainActor
final class PeerStatusCellTests: XCTestCase {
    func testNativeTextAndNameContainCurrentConnectionPingAndEstimate() {
        let field=PeerStatusCell.make(name:"Fixture",address:"127.0.0.1",selected:true,
            status:"Connected; ping 20 ms, total latency about 35 ms")
        XCTAssertTrue(field.stringValue.contains("Fixture, 127.0.0.1, selected, Connected"))
        XCTAssertTrue(field.stringValue.contains("total latency about 35 ms"))
        XCTAssertEqual(field.accessibilityRole(),.staticText)
        XCTAssertEqual(field.accessibilityLabel(),field.stringValue)
        XCTAssertTrue(field.accessibilityHelp()?.contains("not acoustic") == true)
    }
    func testNoChangeDoesNotRewriteAndChangedStatusUsesTheSameField() {
        let field=PeerStatusCell.make(name:"Fixture",address:"127.0.0.1",selected:true,status:"Connected; ping 20 ms")
        let identity=ObjectIdentifier(field)
        XCTAssertFalse(PeerStatusCell.update(field,name:"Fixture",address:"127.0.0.1",selected:true,status:"Connected; ping 20 ms"))
        XCTAssertTrue(PeerStatusCell.update(field,name:"Fixture",address:"127.0.0.1",selected:true,status:"Connected; ping 25 ms"))
        XCTAssertEqual(ObjectIdentifier(field),identity)
        XCTAssertEqual(field.accessibilityLabel(),field.stringValue)
        XCTAssertTrue(field.stringValue.contains("ping 25 ms"))
    }
    func testSelectionAndMissingMeasurementsRemainWordsInTheNativeName() {
        let field=PeerStatusCell.make(name:"Fixture",address:"127.0.0.1",selected:false,
            status:"Not selected; total latency unavailable, output not measured")
        XCTAssertTrue(field.accessibilityLabel()?.contains("not selected") == true)
        XCTAssertTrue(field.accessibilityLabel()?.contains("output not measured") == true)
        XCTAssertFalse(field.isEditable)
    }
    func testHeartbeatStatesUpdateTheSameAccessiblePeerField() {
        let field=PeerStatusCell.make(name:"Fixture",address:"127.0.0.1",selected:true,status:"Waiting for them to select you; ping pending")
        let identity=ObjectIdentifier(field)
        for state in ["ping 25 ms","ping stale 3.0 s","ping unreachable 6.0 s"] {
            XCTAssertTrue(PeerStatusCell.update(field,name:"Fixture",address:"127.0.0.1",selected:true,status:"Connected; "+state))
            XCTAssertEqual(ObjectIdentifier(field),identity)
            XCTAssertTrue(field.accessibilityLabel()?.contains(state)==true)
            XCTAssertTrue(field.accessibilityLabel()?.contains("Fixture, 127.0.0.1, selected")==true)
            XCTAssertEqual(field.accessibilityRole(),.staticText)
            XCTAssertFalse(PeerStatusCell.update(field,name:"Fixture",address:"127.0.0.1",selected:true,status:"Connected; "+state))
        }
    }
}
