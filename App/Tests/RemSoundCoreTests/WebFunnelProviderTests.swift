import Foundation
import RemSoundRuntime
import XCTest
@testable import RemSoundCore

final class WebFunnelProviderTests:XCTestCase {
    typealias F=BrowserListenerAddressTests.Fixture
    func testComposedProviderIsLazyAndRequiresExplicitCurrentRefresh(){let f=F(scoped:true);defer{f.cleanup()};XCTAssertFalse(f.refresh());XCTAssertEqual(f.providers,0);f.ready();XCTAssertEqual(f.providers,0);XCTAssertTrue(f.refresh());f.complete();XCTAssertEqual(f.providers,2);XCTAssertEqual(f.executableInspections,4);XCTAssertEqual(f.plans.count,2);guard case .configured(let token)?=f.values.first else {return XCTFail("No composed address")};XCTAssertEqual(f.copy(token),token.urlString);XCTAssertFalse(f.permissionBindings.isEmpty);XCTAssertTrue(f.permissionBindings.allSatisfy{$0.request==f.request && $0.network==f.binding})}
    func testMissingCurrentSourcePermissionRefusesBeforeProviderFactory(){let f=F(scoped:true);defer{f.cleanup()};f.ready();f.sourcePermission=false;_ = f.refresh();XCTAssertEqual(f.providers,0);XCTAssertEqual(f.executableInspections,0);XCTAssertTrue(f.plans.isEmpty);XCTAssertEqual(f.values,[.unavailable])}
    func testProviderConstructorRevocationCannotReachInspection(){let f=F(scoped:true);defer{f.cleanup()};f.ready();var stopped=false;f.providerHook={XCTAssertTrue(f.service.stop{stopped=true});XCTAssertFalse(stopped)};_ = f.refresh();XCTAssertEqual(f.providers,1);XCTAssertEqual(f.executableInspections,0);XCTAssertTrue(f.plans.isEmpty);XCTAssertTrue(stopped);XCTAssertEqual(f.values,[.cancelled])}
    func testSourceRevocationDuringInspectionPreventsNextFactory(){let f=F(scoped:true);defer{f.cleanup()};f.ready();f.inspectionHook={f.sourceInstalled=false};_ = f.refresh();XCTAssertEqual(f.executableInspections,1);XCTAssertTrue(f.plans.isEmpty);XCTAssertEqual(f.values,[.cancelled])}
    func testQueryCancellationDuringInspectionReachesLiveGate(){let f=F(scoped:true);defer{f.cleanup()};f.ready();f.inspectionHook={f.service.cancelAddressRefresh()};_ = f.refresh();XCTAssertEqual(f.executableInspections,1);XCTAssertTrue(f.plans.isEmpty);XCTAssertEqual(f.values,[.cancelled]);XCTAssertEqual(f.service.status.state,.listening)}
    func testNoSecondStageAfterInstalledProducerLoss(){let f=F(scoped:true);defer{f.cleanup()};f.ready();_ = f.refresh();XCTAssertEqual(f.providers,1);f.sourceInstalled=false;f.finish(0,f.mapping());XCTAssertEqual(f.providers,1);XCTAssertEqual(f.plans.count,1);XCTAssertEqual(f.values,[.cancelled])}
    func testScopedQueryShutdownStillWaitsRawChildAndIndependentRoom(){let f=F(scoped:true);defer{f.cleanup()};f.ready();_ = f.refresh();f.listener.hold=true;var stopped=false;XCTAssertTrue(f.service.shutdown{stopped=true});f.pump();XCTAssertFalse(stopped);XCTAssertFalse(f.gates.first?() ?? true);f.listener.retire();f.pump();XCTAssertFalse(stopped);f.finish(0,"{}");XCTAssertTrue(stopped);XCTAssertEqual(f.values,[.cancelled])}
    func testNativeDependencyConstructorInstallsLazyScopedProviderWithoutStartingSession()throws {
        let session=Session(testPeerPort:1),root=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent("native-provider-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:root)}
        let runtime=try RuntimeConfiguration(options:LaunchOptions.parse(["--config-dir",root.path,"--headless","--silent"]))
        let deps=WebBrowserDependencies.native(runtime,session);XCTAssertNotNil(deps.scopedAddressQuery);XCTAssertNotNil(deps.addressPermission)
        let binding=WebAudioHandoff.Binding(request:UUID(),network:.init(port:6001,generation:UUID()));XCTAssertFalse(deps.addressPermission?(binding) ?? true)
        let queue=DispatchQueue(label:"test.provider.isolated"),done=expectation(description:"isolated provider refuses")
        let launch=deps.scopedAddressQuery?({true}) ?? {_,_ in nil}
        let query=WebFunnelQuery.Service(queue:queue,isolated:false,enabled:true,current:{_ in true},launch:launch)
        XCTAssertTrue(query.request(.init(identity:UUID(),localPort:6001)){result in XCTAssertEqual(result,.failed(.unavailable));done.fulfill()});wait(for:[done],timeout:2)
        let stopped=expectation(description:"query closes"),closed=expectation(description:"stopped Session closes")
        XCTAssertTrue(query.shutdown{stopped.fulfill()});session.shutdown{closed.fulfill()};wait(for:[stopped,closed],timeout:2);XCTAssertEqual(session.testPorts.audio,0);XCTAssertEqual(session.testPorts.bridge,0)
    }
    func testPermissionCallbackCannotReenterIntoStaleProvider(){let f=F(scoped:true);defer{f.cleanup()};f.ready();var closed=false;f.permissionHook={f.permissionHook=nil;XCTAssertTrue(f.service.stop{closed=true});XCTAssertFalse(closed)};_ = f.refresh();XCTAssertEqual(f.providers,0);XCTAssertTrue(f.plans.isEmpty);XCTAssertTrue(closed);XCTAssertEqual(f.values,[.cancelled])}

}
