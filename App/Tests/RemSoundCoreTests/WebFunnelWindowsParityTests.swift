import Foundation
import XCTest
@testable import RemSoundCore

final class WebFunnelWindowsParityTests:XCTestCase {
    func testExplicitTurnOnUsesWindowsCommandWithoutCapabilityPreflight() {
        let f=WebFunnelQueryTests.Fixture()
        XCTAssertTrue(f.service.turnOn(f.scope,openPage:{_,done in done();return true}){f.results.append($0)})
        f.pump()
        XCTAssertEqual(f.plans.first?.arguments,["funnel","--bg",String(f.scope.localPort)])
        XCTAssertEqual(f.plans.first?.timeout,600)
        f.service.cancel();f.finish(0)
    }

    func testMissingDetectionIsGatedBeforeFilesystemOrProcessFactories() {
        let f=WebFunnelQueryTests.Fixture();var missingCalls=0,factories=0,inspections=0
        let launch=WebFunnelExecutable.launch(isolated:true,permitted:{true},inspect:{_,_ in inspections += 1;return nil},missing:{missingCalls += 1;return true},factory:{_,_,_,_ in factories += 1;return nil})
        f.launchHook={sink,_ in XCTAssertNil(launch(.init(query:.turnOn(6001)),sink))}
        XCTAssertTrue(f.service.turnOn(f.scope,openPage:{_,_ in false}){f.results.append($0)});f.pump();f.finish(0)
        XCTAssertEqual(missingCalls,0);XCTAssertEqual(factories,0);XCTAssertEqual(inspections,0)
    }
}
