import Foundation
import XCTest
@testable import RemSoundCore

final class WebFunnelStatusTests:XCTestCase {
    private let host="fixture.tail123.ts.net",port:UInt16=49127
    private func json(_ value:Any)->Data {try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed])}
    private func config(proxy:String?=nil,allowed:Any=true,site:String?=nil,https:Any=true)->[String:Any] {
        let name=site ?? host+":443"
        return ["TCP":["443":["HTTPS":https]],"Web":[name:["Handlers":["/":["Proxy":proxy ?? "http://127.0.0.1:\(port)"]]]],"AllowFunnel":[name:allowed]]
    }
    private func parse(_ value:Any)->WebFunnelStatus.Funnel {WebFunnelStatus.funnel(json(value),exitStatus:0,localPort:port)}
    private func assertMapping(_ value:Any,address:String?=nil,allowed:Bool=true,file:StaticString=#filePath,line:UInt=#line) {
        guard case .mapping(let result,let permission)=parse(value) else {return XCTFail("Expected exact mapping",file:file,line:line)}
        XCTAssertEqual(result.url.absoluteString,address ?? "https://"+host,file:file,line:line);XCTAssertEqual(permission,allowed,file:file,line:line)
    }
    func testExactNumericLoopbackRootAndHTTPSPermissionProduceOnlyAConfigurationValue() {assertMapping(config())}
    func testTrailingProxySlashIsTheSameRootTarget() {assertMapping(config(proxy:"http://127.0.0.1:\(port)/"))}
    func testDisabledOrAbsentAllowFunnelIsNotAnActivePublicClaim() {
        assertMapping(config(allowed:false),allowed:false);var value=config();value.removeValue(forKey:"AllowFunnel");assertMapping(value,allowed:false)
    }
    func testDocumentedAlternateHTTPSPortsArePreserved() {
        for publicPort in [8443,10000] {var value=config(site:host+":\(publicPort)");value["TCP"]=["\(publicPort)":["HTTPS":true]];assertMapping(value,address:"https://"+host+":\(publicPort)")}
    }
    func testEmptyAndNullConfigurationsSayOnlyNoMatchingRoot() {XCTAssertEqual(parse([String:Any]()),.noMatchingRoot);XCTAssertEqual(parse(NSNull()),.noMatchingRoot)}
    func testNonzeroExitAndZeroLocalPortCannotYieldAValue() {
        let data=json(config());XCTAssertEqual(WebFunnelStatus.funnel(data,exitStatus:1,localPort:port),.unknown);XCTAssertEqual(WebFunnelStatus.funnel(data,exitStatus:0,localPort:0),.unknown)
    }
    func testWrongLocalTargetCannotBeClaimedByASuffixMatch() {
        for target in ["http://example.test:\(port)","http://127.0.0.1.evil.test:\(port)","http://127.0.0.1:\(port)/other","http://localhost:\(port)","https://127.0.0.1:\(port)","http://127.0.0.1:1\(port)"] {
            if case .mapping = parse(config(proxy:target)) {XCTFail("Unverified target")}
        }
    }
    func testCredentialsEncodedHostsQueriesAndFragmentsAreNotTargets() {
        for target in ["http://name@127.0.0.1:\(port)","http://127%2e0%2e0%2e1:\(port)","http://127.0.0.1:\(port)?x=1","http://127.0.0.1:\(port)#part"] {if case .mapping=parse(config(proxy:target)) {XCTFail("Unverified target")}}
    }
    func testNonRootHandlerIsNotTheSharedPage() {var value=config();value["Web"]=[host+":443":["Handlers":["/other":["Proxy":"http://127.0.0.1:\(port)"]]]];XCTAssertEqual(parse(value),.noMatchingRoot)}
    func testMissingOrWrongHTTPSModeCannotClaimAMapping() {
        for mode in [false,1,"true",NSNull()] as [Any] {XCTAssertEqual(parse(config(https:mode)),.unknown)}
        var value=config();value.removeValue(forKey:"TCP");XCTAssertEqual(parse(value),.unknown)
    }
    func testAllowFunnelUsesRealBooleansRatherThanNumbersOrStrings() {for value in [1,0,"true",NSNull()] as [Any] {XCTAssertEqual(parse(config(allowed:value)),.unknown)}}
    func testMultipleMatchingSitesAreAmbiguousRatherThanDictionaryOrder() {
        var value=config();value["Web"]=[host+":443":["Handlers":["/":["Proxy":"http://127.0.0.1:\(port)"]]],"other.tail123.ts.net:443":["Handlers":["/":["Proxy":"http://127.0.0.1:\(port)"]]]]
        XCTAssertEqual(parse(value),.unknown)
    }
    func testUntrustedSiteNamesCannotBecomeURLs() {
        for name in ["evil.test:443","fixture.tail123.ts.net.evil.test:443","name@\(host):443","\(host)/path:443","\(host):0443","\(host):80","-bad.tail123.ts.net:443","a..ts.net:443","á.tail123.ts.net:443"] {XCTAssertEqual(parse(config(site:name)),.unknown)}
    }
    func testUnknownForegroundOrServiceNamespacesStayUnknown() {for key in ["Foreground","Services"] {var value=config();value[key]=["other":["Web":[:]]];XCTAssertEqual(parse(value),.unknown)}}
    func testMalformedAndWrongShapeJSONStaysUnknown() {
        for text in ["", "{", "[]", "true", "42", "{\"Web\":[]}", "{\"AllowFunnel\":true}", "{\"Other\":true}"] {XCTAssertEqual(WebFunnelStatus.funnel(Data(text.utf8),exitStatus:0,localPort:port),.unknown)}
    }
    func testDuplicateAndEscapedDuplicateKeysAreNotLastWriterWins() {
        for text in ["{\"Web\":{},\"Web\":{}}", "{\"Web\":{},\"\\u0057eb\":{}}", "{\"x\":{\"a\":1,\"a\":2}}"] {XCTAssertEqual(WebFunnelStatus.funnel(Data(text.utf8),exitStatus:0,localPort:port),.unknown)}
    }
    func testDepthAndValueBudgetsPrecedeFoundationDecoding() {
        let deep="{\"Web\":{},\"x\":"+String(repeating:"[",count:18)+"0"+String(repeating:"]",count:18)+"}"
        XCTAssertEqual(WebFunnelStatus.funnel(Data(deep.utf8),exitStatus:0,localPort:port),.unknown)
        XCTAssertEqual(parse(["Web":[:],"extra":Array(repeating:0,count:WebFunnelStatus.maximumValues)]),.unknown)
    }
    func testOutputCapIsInclusiveAndExcessIsRejected() {
        var data=json(config());data.append(Data(repeating:32,count:WebFunnelStatus.maximumOutputBytes-data.count))
        guard case .mapping=WebFunnelStatus.funnel(data,exitStatus:0,localPort:port) else {return XCTFail("Inclusive byte cap")}
        data.append(32);XCTAssertEqual(WebFunnelStatus.funnel(data,exitStatus:0,localPort:port),.unknown)
    }
    func testSiteAndStringBudgetsRemainBounded() {
        var sites=[String:Any]();for index in 0...WebFunnelStatus.maximumSites {sites["f\(index).tail123.ts.net:443"]=["Handlers":[:]]}
        XCTAssertEqual(parse(["Web":sites]),.unknown);XCTAssertEqual(parse(["Web":[:],"extra":String(repeating:"a",count:WebFunnelStatus.maximumStringBytes+1)]),.unknown)
    }
    func testNodeRunningReportsAValidatedDNSNameWithoutInventingAPublicURL() {
        XCTAssertEqual(WebFunnelStatus.node(json(["BackendState":"Running","Self":["DNSName":host+"."]]),exitStatus:0),.running(dnsName:host))
        XCTAssertEqual(WebFunnelStatus.node(json(["BackendState":"Running"]),exitStatus:0),.running(dnsName:nil))
    }
    func testNodeNotReadyIsExplicitWhileUnknownStatusIsNotGuessed() {
        for state in ["Stopped","NeedsLogin","NeedsMachineAuth","Starting"] {XCTAssertEqual(WebFunnelStatus.node(json(["BackendState":state]),exitStatus:0),.notReady)}
        XCTAssertEqual(WebFunnelStatus.node(json(["BackendState":"FutureState"]),exitStatus:0),.unknown)
    }
    func testNodeErrorsAndInvalidNamesCannotLeakIntoTheResult() {
        for name in ["https://evil.test", "fixture.ts.net.evil.test", "a..tail123.ts.net", "\(host)/path"] {XCTAssertEqual(WebFunnelStatus.node(json(["BackendState":"Running","Self":["DNSName":name]]),exitStatus:0),.unknown)}
        XCTAssertEqual(WebFunnelStatus.node(json(["BackendState":"Running"]),exitStatus:1),.unknown)
    }
    func testNodeOutputUsesTheSameStrictDuplicateAndSizeBoundary() {
        XCTAssertEqual(WebFunnelStatus.node(Data("{\"BackendState\":\"Stopped\",\"BackendState\":\"Running\"}".utf8),exitStatus:0),.unknown)
        XCTAssertEqual(WebFunnelStatus.node(Data(repeating:32,count:WebFunnelStatus.maximumOutputBytes+1),exitStatus:0),.unknown)
    }
    func testQueryPlansAreFixedReadonlyArgvWithoutShellOrArbitraryInputs() {
        XCTAssertEqual(WebFunnelStatus.Query.funnel.arguments,["funnel","status","--json"]);XCTAssertEqual(WebFunnelStatus.Query.node.arguments,["status","--json"])
    }
    func testConflictingOrExtendedRootHandlersCannotBeClaimedAsThePage() {
        for key in ["Path","Text","Redirect","AcceptAppCaps"] {
            var value=config();var handler:[String:Any] = ["Proxy":"http://127.0.0.1:\(port)"]
            if key=="AcceptAppCaps" {handler[key]=["example.test/cap"]} else {handler[key]="other content"}
            value["Web"]=[host+":443":["Handlers":["/":handler]]];XCTAssertEqual(parse(value),.unknown)
        }
    }
    func testUnsupportedTCPProtocolFieldsCannotHideBehindHTTPS() {
        var value=config();value["TCP"]=["443":["HTTPS":true,"ProxyProtocol":2]];XCTAssertEqual(parse(value),.unknown)
    }
    func testConflictingTCPForwardAndHTTPModesRemainUnknown() {
        for extra in [["HTTP":true],["TCPForward":"127.0.0.1:22"],["TerminateTLS":"fixture.tail123.ts.net"]] as [[String:Any]] {
            var mode:[String:Any] = ["HTTPS":true];for (key,value) in extra {mode[key]=value}
            var value=config();value["TCP"]=["443":mode];XCTAssertEqual(parse(value),.unknown)
        }
    }
    func testPermissionForAnotherHostIsNeverAppliedToThisMapping() {
        var value=config();value["AllowFunnel"]=["other.tail123.ts.net:443":true];assertMapping(value,allowed:false)
    }
    func testMalformedNodeSelfAndDNSValueTypesAreNotCoerced() {
        for own in [42,[],["DNSName":true],["DNSName":123]] as [Any] {XCTAssertEqual(WebFunnelStatus.node(json(["BackendState":"Running","Self":own]),exitStatus:0),.unknown)}
    }
    func testInvalidUTF8AndOversizedKeysNeverReachAResult() {
        XCTAssertEqual(WebFunnelStatus.funnel(Data([123,34,255,34,58,48,125]),exitStatus:0,localPort:port),.unknown)
        XCTAssertEqual(parse(["Web":[:],String(repeating:"k",count:WebFunnelStatus.maximumKeyBytes+1):0]),.unknown)
    }
    func testASCIIHostCaseIsCanonicalButRepeatedTrailingDotsAreNot() {
        assertMapping(config(site:host.uppercased()+":443"))
        XCTAssertEqual(WebFunnelStatus.node(json(["BackendState":"Running","Self":["DNSName":host.uppercased()+"."]]),exitStatus:0),.running(dnsName:host))
        XCTAssertEqual(WebFunnelStatus.node(json(["BackendState":"Running","Self":["DNSName":host+".."]]),exitStatus:0),.unknown)
    }
    func testQuotedBracketsAndEscapesAreDataRatherThanStructuralDepth() {
        var value=config();value["extra"]="\"{}[]\\\"";assertMapping(value)
        let count=WebFunnelStatus.maximumSites;var sites=[String:Any]()
        for index in 0..<count {sites["f\(index).tail123.ts.net:443"]=["Handlers":[:]]}
        XCTAssertEqual(parse(["Web":sites]),.noMatchingRoot)
    }

}
