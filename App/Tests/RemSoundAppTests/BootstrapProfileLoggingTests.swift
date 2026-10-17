import Foundation
import XCTest
import RemSoundRuntime
import RemSoundCore
@testable import RemSoundApp

final class BootstrapProfileLoggingTests: XCTestCase {
    private func roots() throws -> (URL, URL) {
        let base=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        let root=base.appendingPathComponent("native")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:base.path)
        addTeardownBlock {try? FileManager.default.removeItem(at:base)}
        return (base,root)
    }
    func testOnlyExplicitOwnedEmptyPrivateDescendantIsEligible() throws {
        let (base,root)=try roots(),env=["REMSOUND_TEST_ROOT":base.path,"REMSOUND_TEST_NATIVE_PROFILE_LOGGING":"1"]
        XCTAssertTrue(BootstrapProfileLogging.accepts(root:root,environment:env))
        XCTAssertFalse(BootstrapProfileLogging.accepts(root:base,environment:env))
        XCTAssertFalse(BootstrapProfileLogging.accepts(root:nil,environment:env))
        XCTAssertFalse(BootstrapProfileLogging.accepts(root:root,environment:["REMSOUND_TEST_ROOT":base.path]))
        try Data([1]).write(to:root.appendingPathComponent("existing"))
        XCTAssertFalse(BootstrapProfileLogging.accepts(root:root,environment:env))
    }
    func testSymlinkAndPublicModeRootsRefuseBeforeFactories() throws {
        let (base,root)=try roots(),env=["REMSOUND_TEST_ROOT":base.path,"REMSOUND_TEST_NATIVE_PROFILE_LOGGING":"1"]
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path)
        XCTAssertFalse(BootstrapProfileLogging.accepts(root:root,environment:env))
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
        let link=base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        XCTAssertFalse(BootstrapProfileLogging.accepts(root:link,environment:env))
        XCTAssertFalse(BootstrapProfileLogging.accepts(root:root,environment:["REMSOUND_TEST_ROOT":"/","REMSOUND_TEST_NATIVE_PROFILE_LOGGING":"1"]))
    }
    func testExactNamedBootstrapInvokesOnlyItsNativeLoggingProvider() throws {
        let name="LOGS PER PROFILE: each profile logs by its own choice, this computer's setting following; never chosen follows the computer; new profiles off"
        var calls=0
        let options=try LaunchOptions.parse(["--selftest","--pack","feature","--only",name])
        let output=try XCTUnwrap(BootstrapSelfCheck.output(for:options,nativeProfileLogging:{calls += 1;return nil}))
        XCTAssertEqual(calls,1)
        let receipt=try JSONDecoder().decode(ProductTestPack.Report.self,from:Data(output.text.utf8))
        XCTAssertEqual(receipt.steps.first?.assertions,21)
        XCTAssertEqual(receipt.steps.first?.status,"UNVERIFIED")
        XCTAssertEqual(output.exitCode,1)
        let known=try LaunchOptions.parse(["--selftest","--pack","feature","--only",ProductTestPack.knownAnswers])
        _=try BootstrapSelfCheck.output(for:known,nativeProfileLogging:{XCTFail("foreign selection invoked native fixture");return nil})
    }
    func testUnsafeScopeAndHelpNeverInvokeNativeProvider() throws {
        let help=try LaunchOptions.parse(["--selftest","--pack","feature","--help"])
        XCTAssertNil(try BootstrapSelfCheck.output(for:help,nativeProfileLogging:{XCTFail("help invoked fixture");return nil}))
        var options=try LaunchOptions.parse(["--selftest","--pack","feature"])
        options.configurationDirectory=URL(fileURLWithPath:"/")
        XCTAssertThrowsError(try BootstrapSelfCheck.output(for:options,nativeProfileLogging:{XCTFail("unsafe root invoked fixture");return nil}))
    }
}
