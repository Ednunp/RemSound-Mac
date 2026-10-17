import Foundation
import XCTest
@testable import RemSoundCore

final class WebFunnelApprovalTests:XCTestCase {
    func testOnlyExactInitialApprovalURLIsAccepted() {
        XCTAssertNotNil(WebFunnelStatus.approvalURL("https://login.tailscale.com/f/serve?node=synthetic"))
        for text in ["http://login.tailscale.com/f/serve","https://login.tailscale.com.evil.invalid/f/serve","https://user@login.tailscale.com/f/serve","https://login.tailscale.com:443/f/serve","https://login.tailscale.com/f/%0aheaders","https://login.tailscale.com/f/serve#x"] {XCTAssertNil(WebFunnelStatus.approvalURL(text))}
    }
    func testPrintedPagesStreamFromBothPipesSplitAndDeduplicated() {
        let f=WebFunnelQueryTests.Fixture();var pages=[URL]()
        XCTAssertTrue(f.service.turnOn(f.scope,openPage:{url,done in pages.append(url);done();return true}){f.results.append($0)})
        f.pump();let sink=f.sinks[0]
        sink.stderr(Data("Enable HTTPS:\nhttps://login.tailscale.com/f/".utf8));f.pump();XCTAssertTrue(pages.isEmpty)
        sink.stderr(Data("serve?node=synthetic\n".utf8));f.pump();XCTAssertEqual(pages.count,1)
        sink.stdout(Data("https://login.tailscale.com/f/serve?node=synthetic\nhttps://login.tailscale.com/f/funnel?node=synthetic\n".utf8));f.pump();XCTAssertEqual(pages.count,2)
        XCTAssertTrue(f.results.isEmpty);f.finish(0);XCTAssertEqual(f.results,[.turnedOn]);XCTAssertEqual(f.plans.count,1)
    }
    func testUnsafeOrOversizedLinesNeverBecomeBrowserDestinations() {
        let f=WebFunnelQueryTests.Fixture();var pages=[URL]()
        XCTAssertTrue(f.service.turnOn(f.scope,openPage:{url,done in pages.append(url);done();return true}){f.results.append($0)})
        f.pump();f.sinks[0].stdout(Data(("https://login.tailscale.com.evil.invalid/\nhttps://login.tailscale.com/f/%0aheader\n"+String(repeating:"x",count:4097)+"https://login.tailscale.com/f/serve\n").utf8));f.finish(0)
        XCTAssertTrue(pages.isEmpty);XCTAssertEqual(f.results,[.turnedOn])
    }
    func testCancelWaitsChildIOAndRawBrowserReturn() {
        let f=WebFunnelQueryTests.Fixture();var pageReturn:(()->Void)?
        XCTAssertTrue(f.service.turnOn(f.scope,openPage:{_,done in pageReturn=done;return true}){f.results.append($0)})
        f.pump();f.sinks[0].stderr(Data("https://login.tailscale.com/f/serve\n".utf8));f.pump();XCTAssertNotNil(pageReturn)
        XCTAssertTrue(f.service.shutdown{f.shutdowns += 1});f.finish(0);XCTAssertTrue(f.results.isEmpty);XCTAssertEqual(f.shutdowns,0)
        pageReturn?();pageReturn?();f.pump();XCTAssertEqual(f.results,[.failed(.cancelled)]);XCTAssertEqual(f.shutdowns,1)
    }
    func testScopeLossBeforePageDrainNeverOpensIt() {
        let f=WebFunnelQueryTests.Fixture();var opens=0
        XCTAssertTrue(f.service.turnOn(f.scope,openPage:{_,done in opens += 1;done();return true}){f.results.append($0)})
        f.pump();f.queue.sync {f.current=false;f.sinks[0].stdout(Data("https://login.tailscale.com/f/serve\n".utf8))};f.finish(0)
        XCTAssertEqual(opens,0);XCTAssertEqual(f.results,[.failed(.cancelled)])
    }
    func testRefusedBrowserDoesNotInventCompletionOrBlockChildRetirement() {
        let f=WebFunnelQueryTests.Fixture()
        XCTAssertTrue(f.service.turnOn(f.scope,openPage:{_,_ in false}){f.results.append($0)})
        f.pump();f.end(0,"https://login.tailscale.com/f/serve\n",status:9);XCTAssertEqual(f.results,[.failed(.commandFailed)])
    }
    func testNativeBrowserBoundaryRefusesIsolationBeforeHandoff() {
        var gates=0
        XCTAssertFalse(WebFunnelApprovalBrowser.open(WebFunnelStatus.downloadPage,isolated:true,permitted:{gates += 1;return true},completion:{_ in XCTFail()}));XCTAssertEqual(gates,0)
    }
}
