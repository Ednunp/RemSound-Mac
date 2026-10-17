import Darwin
import Security
import XCTest
@testable import RemSoundCore

final class WebFunnelImageNativeTests:XCTestCase {
    typealias V=WebFunnelProcessNativeTests.Visit
    let helpers=WebFunnelProcessNativeTests()
    func path()throws->URL {try helpers.visit("normal").path}
    func absent(_ path:URL,file:StaticString=#filePath,line:UInt=#line){XCTAssertFalse(FileManager.default.fileExists(atPath:path.path+".pid"),file:file,line:line)}
    func stopped(_ pid:pid_t,file:StaticString=#filePath,line:UInt=#line){var info=proc_bsdinfo();let size=Int32(MemoryLayout<proc_bsdinfo>.size);XCTAssertEqual(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size),size,file:file,line:line);XCTAssertEqual(info.pbi_status,4,file:file,line:line);XCTAssertEqual(info.pbi_pgid,UInt32(pid),file:file,line:line);XCTAssertEqual(info.pbi_ppid,UInt32(getpid()),file:file,line:line)}
    func testActualImageIsSuspendedBeforeVerificationAndResumesOnlyAfterAcceptance()throws {
        let path=try path();var ids=[pid_t]()
        let v=try V(path,verify:{pid,gate in self.stopped(pid);if ids.isEmpty {self.absent(path)};ids.append(pid);return gate()})
        v.start();v.wait();XCTAssertEqual(ids.count,2);for id in ids {helpers.assertReaped(id)};guard case .mapping?=v.results.first else {v.close();return XCTFail("Expected both owned fixture queries")};v.close()
    }
    func testRefusedActualChildNeverExecutesFixtureCodeAndIsReaped()throws {
        let path=try path();var id:pid_t=0
        let v=try V(path,verify:{pid,_ in id=pid;self.stopped(pid);self.absent(path);return false})
        v.start();v.wait();XCTAssertGreaterThan(id,0);absent(path);helpers.assertReaped(id);XCTAssertEqual(v.results,[.failed(.unavailable)]);v.close()
    }
    func testCancellationInsideActualVerificationCannotResume()throws {
        let path=try path();var id:pid_t=0;weak var current:V?
        let v=try V(path,verify:{pid,_ in id=pid;current?.service.cancel();return true});current=v
        v.start();v.wait();absent(path);helpers.assertReaped(id);XCTAssertEqual(v.results,[.failed(.cancelled)]);v.close()
    }
    func testShutdownRetainsBlockedRawVerificationAndSuspendedChild()throws {
        let path=try path(),entered=XCTestExpectation(description:"owned verifier entered"),released=DispatchSemaphore(value:0),stopped=XCTestExpectation(description:"shutdown after raw return")
        var id:pid_t=0,shutdownReturned=false
        let v=try V(path,verify:{pid,gate in id=pid;entered.fulfill();released.wait();return gate()})
        v.start();XCTAssertEqual(XCTWaiter().wait(for:[entered],timeout:2),.completed);self.stopped(id);absent(path)
        XCTAssertTrue(v.service.shutdown{shutdownReturned=true;stopped.fulfill()});v.queue.sync{};XCTAssertFalse(v.service.request(.init(identity:UUID(),localPort:6001)){_ in XCTFail("Refused work callback")});XCTAssertFalse(shutdownReturned)
        released.signal();v.wait();XCTAssertEqual(XCTWaiter().wait(for:[stopped],timeout:2),.completed);absent(path);helpers.assertReaped(id);XCTAssertTrue(shutdownReturned);v.close()
    }
    func testActualDynamicSecurityRefusesForeignSignerBeforeFixtureRuns()throws {
        let path=try path(),proof=WebFunnelExecutable.approve(validExecutableInspection())!;var id:pid_t=0
        let v=try V(path,verify:{pid,gate in id=pid;return WebFunnelExecutable.verifyRunning(pid,proof:proof,isolated:false,permitted:gate)})
        v.start();v.wait();XCTAssertGreaterThan(id,0);absent(path);helpers.assertReaped(id);XCTAssertEqual(v.results,[.failed(.unavailable)]);v.close()
    }
    func testDynamicRequirementParsesWithCurrentSDK() {
        let proof=WebFunnelExecutable.approve(validExecutableInspection())!;var requirement:SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(proof.runningRequirement as CFString,[],&requirement),errSecSuccess);XCTAssertNotNil(requirement)
    }
    func testIsolatedDynamicCheckRefusesBeforePermissionOrSecurityWork(){var calls=0;let proof=WebFunnelExecutable.approve(validExecutableInspection())!;XCTAssertFalse(WebFunnelExecutable.verifyRunning(getpid(),proof:proof,isolated:true,permitted:{calls += 1;return true}));XCTAssertEqual(calls,0)}
    func testInvalidGuestPIDRefusesBeforePermissionOrSecurityWork(){var calls=0;let proof=WebFunnelExecutable.approve(validExecutableInspection())!;for pid in [pid_t(0),pid_t(-1)] {XCTAssertFalse(WebFunnelExecutable.verifyRunning(pid,proof:proof,isolated:false,permitted:{calls += 1;return true}))};XCTAssertEqual(calls,0)}
    func testOwnedSuspendedGuestDynamicHashValidationPositiveAndMismatch()throws {
        let path=try path();var checked=0
        let v=try V(path,verify:{pid,gate in
            self.stopped(pid);var guest:SecCode?,origin:SecStaticCode?,fields:CFDictionary?,requirement:SecRequirement?
            let attributes=[kSecGuestAttributePid as String:NSNumber(value:pid)] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil,attributes,[],&guest)==errSecSuccess,let guest,
                  SecCodeCopyStaticCode(guest,[],&origin)==errSecSuccess,let origin,
                  SecCodeCopySigningInformation(origin,[],&fields)==errSecSuccess,let info=fields as? [String:Any],let digest=info[kSecCodeInfoUnique as String] as? Data else {XCTFail("Owned suspended guest unavailable");return false}
            let hash=digest.map{String(format:"%02x",$0)}.joined();XCTAssertEqual(digest.count,20)
            XCTAssertEqual(SecRequirementCreateWithString("cdhash H\"\(hash)\"" as CFString,[],&requirement),errSecSuccess)
            XCTAssertEqual(SecCodeCheckValidity(guest,[],requirement),errSecSuccess)
            var wrong:SecRequirement?;XCTAssertEqual(SecRequirementCreateWithString("cdhash H\"0000000000000000000000000000000000000000\"" as CFString,[],&wrong),errSecSuccess)
            XCTAssertNotEqual(SecCodeCheckValidity(guest,[],wrong),errSecSuccess);checked += 1;return gate()
        })
        v.start();v.wait();XCTAssertEqual(checked,2);guard case .mapping?=v.results.first else {v.close();return XCTFail("Owned dynamic positive gate failed")};v.close()
    }
}
