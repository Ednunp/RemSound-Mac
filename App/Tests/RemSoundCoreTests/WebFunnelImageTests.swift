import XCTest
@testable import RemSoundCore

final class WebFunnelImageTests:XCTestCase {
    typealias F=WebFunnelProcessTests.Fixture
    func testAdmissionBeforeFirstReadAndExactlyOnce(){let f=F();f.resource.hook={kind in if kind=="output" || kind=="error" {XCTAssertEqual(f.resource.admissions,1)}};f.run();XCTAssertEqual(f.resource.admissions,1);XCTAssertEqual(f.results,[.unknown])}
    func testRefusedImageNeverDeliversOutputAndStillRetires(){let f=F();f.resource.admitResult=false;f.run();XCTAssertEqual(f.results,[.failed(.unavailable)]);XCTAssertEqual(f.resource.signals.first,.terminate);XCTAssertEqual(f.resource.reaps,1);XCTAssertEqual(f.resource.closes.count,2)}
    func testPermissionLostDuringInspectionCannotAdmit(){let f=F();f.resource.admitHook={f.enabled=false};f.run();XCTAssertEqual(f.results,[.failed(.cancelled)]);XCTAssertEqual(f.resource.admissions,1);XCTAssertEqual(f.resource.reaps,1)}
    func testCancellationDuringInspectionCannotAdmit(){let f=F();f.resource.admitHook={f.service.cancel()};f.run();XCTAssertEqual(f.results,[.failed(.cancelled)]);XCTAssertEqual(f.resource.admissions,1)}
    func testDeadlineIncludesRawInspectionReturn(){let f=F();f.resource.admitHook={f.now=11};f.run();XCTAssertEqual(f.results,[.failed(.timedOut)]);XCTAssertEqual(f.resource.admissions,1);XCTAssertEqual(f.resource.reaps,1)}
    func testInspectionClockFailureIsNotAnImageFailure(){let f=F();f.resource.admitHook={f.now = .nan};f.run();XCTAssertEqual(f.results,[.failed(.io)]);XCTAssertEqual(f.resource.admissions,1);XCTAssertEqual(f.resource.reaps,1)}
    func testSetupFailureNeverInspectsUnreadyChild(){let f=F();f.resource.setupFailed=true;f.run();XCTAssertEqual(f.resource.admissions,0);XCTAssertEqual(f.results,[.failed(.io)])}
    func testBackwardAdmissionClockCannotRecoverIntoPermission(){let f=F();f.resource.gateHook={gate in f.now=3;XCTAssertTrue(gate());f.now=2;XCTAssertFalse(gate());f.now=4;XCTAssertFalse(gate())};f.run();XCTAssertEqual(f.results,[.failed(.io)])}
    func testExpiredAdmissionCannotRecoverWithAnEarlierClock(){let f=F();f.resource.gateHook={gate in f.now=11;XCTAssertFalse(gate());f.now=2;XCTAssertFalse(gate())};f.run();XCTAssertEqual(f.results,[.failed(.timedOut)])}
    func testDynamicRequirementSealsExactApprovedHashAndSigner(){let proof=WebFunnelExecutable.approve(validExecutableInspection())!;XCTAssertEqual(proof.runningRequirement,"anchor apple generic and certificate leaf[subject.OU] = \"W5364U7YZB\" and identifier \"io.tailscale.ipn.macsys\" and cdhash H\"0101010101010101010101010101010101010101\"");var other=validExecutableInspection();other.digest=Data(repeating:2,count:20);XCTAssertNotEqual(proof.runningRequirement,WebFunnelExecutable.approve(other)?.runningRequirement)}
}
