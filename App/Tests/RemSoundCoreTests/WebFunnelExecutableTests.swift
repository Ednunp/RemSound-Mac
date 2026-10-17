import Foundation
import XCTest
@testable import RemSoundCore

func validExecutableInspection()->WebFunnelExecutable.Inspection {
    let stamp=WebFunnelExecutable.Stamp(device:1,inode:1,size:1,modified:1,changed:1,regular:true,executable:true,symlink:false,writableByOthers:false)
    return .init(identifier:"io.tailscale.ipn.macsys",teamIdentifier:WebFunnelExecutable.team,version:"1.96.2",executableName:"Tailscale",digest:Data(repeating:1,count:20),before:stamp,after:stamp,metadataBytes:1024,signatureValid:true,resourcesValid:true,offline:true)
}
final class WebFunnelExecutableTests:XCTestCase {
    final class Child:WebFunnelQuery.Child {var cancelled=0;func cancel(){cancelled += 1}}
    final class Fixture {
        let queue=DispatchQueue(label:"test.Funnel.executable"),scope=WebFunnelQuery.Scope(identity:UUID(),localPort:6001)
        var service:WebFunnelQuery.Service!,allowed=true,inspection:WebFunnelExecutable.Inspection? = validExecutableInspection(),reads=[URL](),children=[Child](),sinks=[WebFunnelQuery.Sink](),results=[WebFunnelQuery.Result]()
        var inspectionGates=[()->Bool](),hook:(()->Void)?
        init(isolated:Bool=false){let launch=WebFunnelExecutable.launch(isolated:isolated,permitted:{[unowned self] in allowed},inspect:{[unowned self] url,gate in reads.append(url);inspectionGates.append(gate);hook?();return inspection},factory:{[unowned self] proof,plan,sink,gate in XCTAssertEqual(proof.url,WebFunnelExecutable.executable);XCTAssertTrue(gate());let child=Child();children.append(child);sinks.append(sink);return child});service=WebFunnelQuery.Service(queue:queue,isolated:false,enabled:true,current:{[unowned self] in $0==scope && allowed},launch:launch)}
        func pump(){for _ in 0..<32 {queue.sync{}}}
        func request(){XCTAssertTrue(service.request(scope){[unowned self] in results.append($0)});pump()}
        func finish(_ text:String){guard let sink=sinks.last else {return XCTFail("No child")};sink.stdout(Data(text.utf8));sink.stdoutClosed();sink.stderrClosed();sink.exited(0);sink.retired();pump()}
        func cleanup(){_ = service.shutdown{};for sink in sinks {sink.stdoutClosed();sink.stderrClosed();sink.exited(0);sink.retired()};pump()}
    }
    func testRecognizesOnlySignedOfficialBundleIdentities(){for identifier in WebFunnelExecutable.identifiers {var value=validExecutableInspection();value.identifier=identifier;XCTAssertNotNil(WebFunnelExecutable.approve(value))}}
    func testRejectsWrongTeamIdentifierAndExecutableName(){for key in 0..<3 {var value=validExecutableInspection();if key==0 {value.teamIdentifier="untrusted"};if key==1 {value.identifier="other.app"};if key==2 {value.executableName="other"};XCTAssertNil(WebFunnelExecutable.approve(value))}}
    func testStrictVersionPolicyForModernFunnelCommandFamily(){for text in ["1.52.0","1.96.2","1.100.12"] {var value=validExecutableInspection();value.version=text;XCTAssertNotNil(WebFunnelExecutable.approve(value))};for text in ["1.51.99","2.0.0","1.52","1.52.0-beta","1.052.0","1.52.0 ","１.52.0",String(repeating:"1",count:100)] {var value=validExecutableInspection();value.version=text;XCTAssertNil(WebFunnelExecutable.approve(value),text)}}
    func testSignatureResourceOfflineAndMetadataCaps(){for key in 0..<5 {var value=validExecutableInspection();if key==0 {value.signatureValid=false};if key==1 {value.resourcesValid=false};if key==2 {value.offline=false};if key==3 {value.metadataBytes=65537};if key==4 {value.digest=Data(repeating:0,count:21)};XCTAssertNil(WebFunnelExecutable.approve(value))}}
    func testStampMustRemainExactAcrossInspection(){for key in 0..<5 {var value=validExecutableInspection();if key==0 {value.after.inode += 1};if key==1 {value.after.modified += 1};if key==2 {value.after.changed += 1};if key==3 {value.after.device += 1};if key==4 {value.after.size += 1};XCTAssertNil(WebFunnelExecutable.approve(value))}}
    func testUnsafeFileShapesAndModesRefuse(){for key in 0..<5 {var value=validExecutableInspection();if key==0 {value.before.regular=false};if key==1 {value.before.executable=false};if key==2 {value.before.symlink=true};if key==3 {value.before.writableByOthers=true};if key==4 {value.before.inode=0};value.after=value.before;XCTAssertNil(WebFunnelExecutable.approve(value))}}
    func testExecutableSizeCapIsEnforcedByApprovalAsWellAsNativeReader(){var value=validExecutableInspection();value.before.size=536_870_912;value.after=value.before;XCTAssertNotNil(WebFunnelExecutable.approve(value));value.before.size += 1;value.after=value.before;XCTAssertNil(WebFunnelExecutable.approve(value))}
    func testOffAndIsolatedRefuseBeforeAnyInspection(){for isolated in [false,true] {let f=Fixture(isolated:isolated);defer{f.cleanup()};if !isolated {f.allowed=false};f.request();XCTAssertTrue(f.reads.isEmpty);XCTAssertTrue(f.children.isEmpty)}}
    func testFixedApplicationLocationAndReproofBeforeEachReadOnlyStage(){let f=Fixture();defer{f.cleanup()};f.request();XCTAssertEqual(f.children.count,1);XCTAssertEqual(f.reads,[WebFunnelExecutable.bundle,WebFunnelExecutable.bundle]);f.finish("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"mac.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:6001\"}}}},\"AllowFunnel\":{\"mac.tail.ts.net:443\":true}}");XCTAssertEqual(f.children.count,2);f.finish("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"mac.tail.ts.net.\"}}");guard case .mapping?=f.results.first else {return XCTFail("No scoped mapping")};XCTAssertEqual(f.reads.count,4)}
    func testMissingInspectionIsUnavailableWithNoFallback(){let f=Fixture();defer{f.cleanup()};f.inspection=nil;f.request();XCTAssertTrue(f.children.isEmpty);XCTAssertEqual(f.results,[.failed(.unavailable)]);XCTAssertEqual(f.reads.count,1)}
    func testReentrantRevocationBeforeInspectionReturnCannotLaunch(){let f=Fixture();defer{f.cleanup()};f.hook={f.allowed=false};f.request();XCTAssertEqual(f.reads.count,1);XCTAssertTrue(f.children.isEmpty);XCTAssertEqual(f.results,[.failed(.unavailable)])}
    func testReplacementBetweenApprovalAndFactoryCannotLaunch(){let f=Fixture();defer{f.cleanup()};f.hook={if f.reads.count==2 {f.inspection?.digest=Data(repeating:2,count:20)}};f.request();XCTAssertEqual(f.reads.count,2);XCTAssertTrue(f.children.isEmpty);XCTAssertEqual(f.results,[.failed(.unavailable)])}
    func testInspectionReceivesLiveSinkPermissionNotAnUnconditionalGate(){let f=Fixture();defer{f.cleanup()};f.hook={f.service.cancel();XCTAssertFalse(f.inspectionGates.last?() ?? true)};f.request();XCTAssertEqual(f.reads.count,1);XCTAssertTrue(f.children.isEmpty);XCTAssertEqual(f.results,[.failed(.cancelled)])}

}
