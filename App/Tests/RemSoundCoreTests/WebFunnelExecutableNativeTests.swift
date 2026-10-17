import Foundation
import Security
import XCTest
@testable import RemSoundCore

final class WebFunnelExecutableNativeTests:XCTestCase {
    private func fixture()throws->URL {
        let base=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent("exe-\(UUID().uuidString)")
        let root=base.appendingPathComponent("Tailscale.app",isDirectory:true),mac=root.appendingPathComponent("Contents/MacOS",isDirectory:true)
        try FileManager.default.createDirectory(at:mac,withIntermediateDirectories:true,attributes:[.posixPermissions:0o755])
        let info:[String:Any] = ["CFBundleIdentifier":"io.tailscale.ipn.macsys","CFBundleExecutable":"Tailscale","CFBundleShortVersionString":"1.96.2","CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
        let executable=mac.appendingPathComponent("Tailscale");try Data("not executable code".utf8).write(to:executable);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        addTeardownBlock {try FileManager.default.removeItem(at:base)};return root
    }
    func testStaticValidationFlagsDoNotEnableNetworkOrSkipResources(){let flags=WebFunnelExecutable.validationFlags.rawValue;XCTAssertEqual(flags & kSecCSAllowNetworkAccess,0);XCTAssertEqual(flags & kSecCSDoNotValidateResources,0);XCTAssertEqual(flags & kSecCSDoNotValidateExecutable,0);XCTAssertNotEqual(flags & kSecCSStrictValidate,0);XCTAssertNotEqual(flags & kSecCSCheckAllArchitectures,0)}
    func testDefaultIsolationRefusesBeforePermissionOrFileInspection(){var calls=0;XCTAssertNil(WebFunnelExecutable.inspectNative(URL(fileURLWithPath:"/not-read/Tailscale.app"),isolated:true,permitted:{calls += 1;return true}));XCTAssertEqual(calls,0)}
    func testOwnedUnsignedBundleCannotBecomeApprovedExecutable()throws{let root=try fixture();XCTAssertNil(WebFunnelExecutable.inspectNative(root,isolated:false,permitted:{true}))}
    func testOwnedSymlinkAndOversizedMetadataRefuse()throws{let root=try fixture(),alias=root.deletingLastPathComponent().appendingPathComponent("alias/Tailscale.app");try FileManager.default.createDirectory(at:alias.deletingLastPathComponent(),withIntermediateDirectories:true);try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root);XCTAssertNil(WebFunnelExecutable.inspectNative(alias,isolated:false,permitted:{true}));try Data(repeating:0,count:65_537).write(to:root.appendingPathComponent("Contents/Info.plist"));XCTAssertNil(WebFunnelExecutable.inspectNative(root,isolated:false,permitted:{true}))}
    func testOwnedUnsafeExecutableModeAndDecoratedURLRefuse()throws{let root=try fixture();try FileManager.default.setAttributes([.posixPermissions:0o777],ofItemAtPath:root.appendingPathComponent("Contents/MacOS/Tailscale").path);XCTAssertNil(WebFunnelExecutable.inspectNative(root,isolated:false,permitted:{true}));XCTAssertNil(WebFunnelExecutable.inspectNative(try XCTUnwrap(URL(string:root.absoluteString+"?query")),isolated:false,permitted:{true}))}
    func testPermissionLossAtEveryAvailableInspectionStageNeverApproves()throws{let root=try fixture();for limit in 0..<10 {var calls=0;let result=WebFunnelExecutable.inspectNative(root,isolated:false,permitted:{calls += 1;return calls<=limit});XCTAssertNil(result)}}
}
