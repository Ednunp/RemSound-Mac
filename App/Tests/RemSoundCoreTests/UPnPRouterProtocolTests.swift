import Foundation
import XCTest
@testable import RemSoundCore

final class UPnPRouterProtocolTests: XCTestCase {
    private let gateway = "192.0.2.1", location = URL(string:"http://192.0.2.1:5000/router/description.xml")!
    private var service: UPnPRouterService { .init(kind:.ip2,controlURL:URL(string:"http://192.0.2.1:5000/control")!,gatewayAddress:gateway) }
    private func entry(_ kind: UPnPRouterService.Kind = .ip2, _ control: String = "/control") -> String {
        "<service><serviceType>\(kind.rawValue)</serviceType><serviceId>urn:fixture:id</serviceId><controlURL>\(control)</controlURL><eventSubURL>/event</eventSubURL><SCPDURL>/service.xml</SCPDURL></service>"
    }
    private func description(_ entries: String, base: String = "", extra: String = "") -> Data {
        Data("<root xmlns=\"urn:schemas-upnp-org:device-1-0\">\(base)<device><deviceType>\(UPnPRouterProtocol.igd2)</deviceType><deviceList><device><deviceType>urn:schemas-upnp-org:device:WANDevice:2</deviceType><deviceList><device><deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:2</deviceType><serviceList>\(entries)</serviceList></device></deviceList></device></deviceList></device>\(extra)</root>".utf8)
    }
    private func discovered(_ url: String = "http://192.0.2.1:5000/router/description.xml", extra: String = "", source: Endpoint? = nil) -> URL? {
        let text = "HTTP/1.1 200 OK\r\nLoCaTiOn: \(url)\r\nST: \(UPnPRouterProtocol.igd2)\r\nUSN: uuid:fixture::\(UPnPRouterProtocol.igd2)\r\n\(extra)\r\n"
        return UPnPRouterProtocol.discovery(Data(text.utf8),from:source ?? Endpoint(gateway,1900),gatewayAddress:gateway)
    }
    private func parsed(_ data: Data) -> [UPnPRouterService] { UPnPRouterProtocol.services(data,location:location,gatewayAddress:gateway) }
    private func envelope(_ child: String) -> Data { Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>\(child)</s:Body></s:Envelope>".utf8) }
    private func response(_ action: UPnPRouterProtocol.Action, contents: String = "", kind: UPnPRouterService.Kind = .ip2) -> Data {
        envelope("<u:\(action.rawValue)Response xmlns:u=\"\(kind.rawValue)\">\(contents)</u:\(action.rawValue)Response>")
    }
    func testSearchIsFiniteQuotedDiscoveryAndRefusesArbitraryTargets() {
        XCTAssertEqual(UPnPRouterProtocol.search(),Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(UPnPRouterProtocol.igd1)\r\n\r\n".utf8))
        XCTAssertNotNil(UPnPRouterProtocol.search(target:UPnPRouterProtocol.igd2))
        XCTAssertNil(UPnPRouterProtocol.search(target:"ssdp:all\r\nBad: value"))
    }
    func testDiscoveryAcceptsCaseInsensitiveHeadersOnKnownGateway() { XCTAssertEqual(discovered(),location) }
    func testDiscoveryRejectsDifferentSourceDnsCredentialsFragmentsAndSchemes() {
        XCTAssertNil(discovered(source:Endpoint("192.0.2.2",1900)))
        for url in ["http://192.0.2.2/x","http://example.invalid/x","http://127.0.0.1/x","file:///tmp/x","http://u:p@192.0.2.1/x","http://192.0.2.1/x#part","http://192.0.2.1/%0d%0aX","http://192.0.2.1:0/x"] { XCTAssertNil(discovered(url),url) }
    }
    func testDiscoveryRejectsDuplicateFoldedOversizeStatusAndBody() {
        XCTAssertNil(discovered(extra:"LOCATION: http://192.0.2.1/other\r\n"))
        XCTAssertNil(discovered(extra:" folded: value\r\n"))
        XCTAssertNil(discovered(extra:String(repeating:"x",count:UPnPRouterProtocol.maximumSSDPBytes)))
        let text="HTTP/1.1 500 Error\r\nLOCATION: http://192.0.2.1/x\r\nST: \(UPnPRouterProtocol.igd1)\r\nUSN: uuid:fixture\r\n\r\n"
        XCTAssertNil(UPnPRouterProtocol.discovery(Data(text.utf8),from:Endpoint(gateway,1900),gatewayAddress:gateway))
        XCTAssertNil(UPnPRouterProtocol.discovery(Data(text.replacingOccurrences(of:"500 Error",with:"200 OK").utf8)+Data("body".utf8),from:Endpoint(gateway,1900),gatewayAddress:gateway))
    }
    func testServicesPreferIp2ThenIp1ThenPppWithStableDeduplication() {
        let values=parsed(description(entry(.ppp1,"/ppp")+entry(.ip1,"/ip1")+entry(.ip2,"/ip2")+entry(.ip2,"/ip2")))
        XCTAssertEqual(values.map(\.kind),[.ip2,.ip1,.ppp1]);XCTAssertEqual(values.map(\.controlURL.path),["/ip2","/ip1","/ppp"])
    }
    func testDescriptionRequiresActualGatewayWanDeviceHierarchyAndNamespace() {
        let valid=String(data:description(entry()),encoding:.utf8)!
        for changed in [valid.replacingOccurrences(of:UPnPRouterProtocol.igd2,with:"urn:fixture:printer"),valid.replacingOccurrences(of:"WANDevice:2",with:"OtherDevice:2"),valid.replacingOccurrences(of:"WANConnectionDevice:2",with:"OtherDevice:2"),valid.replacingOccurrences(of:"device-1-0",with:"wrong-1-0")] { XCTAssertTrue(parsed(Data(changed.utf8)).isEmpty) }
    }
    func testRelativeUrlBaseAndDifferentGatewayPortAreSupported() {
        let value=parsed(description(entry(.ip1,"control"),base:"<URLBase>http://192.0.2.1:80/base/</URLBase>")).first
        XCTAssertEqual(value?.controlURL.absoluteString,"http://192.0.2.1:80/base/control")
        XCTAssertEqual(parsed(description(entry(.ip1,"../control"))).first?.controlURL.absoluteString,"http://192.0.2.1:5000/control")
    }
    func testControlAndBaseCannotEscapeGatewayOrChangeScheme() {
        for path in ["http://192.0.2.2/control","//example.invalid/control","https://192.0.2.1/control","http://u@192.0.2.1/control","/control#fragment","/%0a","http://192.0.2.1:65536/control"] { XCTAssertTrue(parsed(description(entry(.ip2,path))).isEmpty,path) }
        for base in ["http://192.0.2.2/","https://192.0.2.1/","file:///x/"] { XCTAssertTrue(parsed(description(entry(),base:"<URLBase>\(base)</URLBase>")).isEmpty) }
    }
    func testDuplicateServiceFieldsAndUnsupportedTypesAreIgnoredAndCountBounded() {
        let dup=entry().replacingOccurrences(of:"<controlURL>",with:"<controlURL>/second</controlURL><controlURL>")
        XCTAssertTrue(parsed(description(dup)).isEmpty)
        XCTAssertTrue(parsed(description(entry().replacingOccurrences(of:UPnPRouterService.Kind.ip2.rawValue,with:"urn:fixture:arbitrary"))).isEmpty)
        XCTAssertEqual(parsed(description((0..<12).map {entry(.ip2,"/c\($0)")}.joined())).count,8)
    }
    func testXmlBoundsDtdEncodingAndMalformedDocumentsRefused() {
        let valid=description(entry()), text=String(data:valid,encoding:.utf8)!
        XCTAssertTrue(parsed(Data("<!DOCTYPE root [<!ENTITY remote SYSTEM 'http://example.invalid/private'>]>".utf8)+valid).isEmpty)
        XCTAssertTrue(parsed(text.data(using:.utf16)!).isEmpty)
        XCTAssertTrue(parsed(Data(repeating:32,count:UPnPRouterProtocol.maximumDescriptionBytes+1)).isEmpty)
        XCTAssertTrue(parsed(description(entry(),extra:String(repeating:"<x>",count:40)+String(repeating:"</x>",count:40))).isEmpty)
        XCTAssertTrue(parsed(description(entry(),extra:String(repeating:"<x/>",count:1100))).isEmpty)
        XCTAssertTrue(parsed(description(entry(),extra:"<x>"+String(repeating:"x",count:140000)+"</x>")).isEmpty)
        XCTAssertTrue(parsed(Data(text.dropLast().utf8)).isEmpty)
    }
    func testAddRequestHasOrderedUdpFieldsAndQuotedSoapAction() throws {
        let value=try XCTUnwrap(UPnPRouterProtocol.request(service,action:.add,internalClient:"192.0.2.10",internalPort:47830,externalPort:49321))
        XCTAssertEqual(value.url,service.controlURL);XCTAssertEqual(value.soapAction,"\"\(service.kind.rawValue)#AddPortMapping\"")
        let body=String(data:value.body,encoding:.utf8)!
        XCTAssertTrue(body.contains("<NewRemoteHost></NewRemoteHost><NewExternalPort>49321</NewExternalPort><NewProtocol>UDP</NewProtocol><NewInternalPort>47830</NewInternalPort><NewInternalClient>192.0.2.10</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>RemSound audio</NewPortMappingDescription><NewLeaseDuration>3600</NewLeaseDuration>"))
    }
    func testAddOwnershipDescriptionEscapesXmlAndFlowsThroughTypedHttpRequest() throws {
        let description = "RemSound-<&\"'>"
        let request = try XCTUnwrap(RouterHTTPTransport.Request.soap(service: service, action: .add, internalClient: "192.0.2.10", internalPort: 47830, externalPort: 47830, mappingDescription: description))
        XCTAssertEqual(request.action, .add)
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.contains("<NewPortMappingDescription>RemSound-&lt;&amp;&quot;&apos;&gt;</NewPortMappingDescription>"))
    }
    func testAddDescriptionBoundsControlsAndBlankAreRejected() {
        for description in ["", " ", "bad\nvalue", String(repeating: "x", count: 65)] {
            XCTAssertNil(UPnPRouterProtocol.request(service, action: .add, internalClient: "192.0.2.10", internalPort: 47830, externalPort: 47830, mappingDescription: description))
        }
    }
    func testDeleteUsesActualExternalPortAndNoWildcardOrOtherClient() throws {
        let value=try XCTUnwrap(UPnPRouterProtocol.request(service,action:.delete,externalPort:49321))
        let body=String(data:value.body,encoding:.utf8)!
        XCTAssertTrue(body.contains("<NewExternalPort>49321</NewExternalPort><NewProtocol>UDP</NewProtocol>"));XCTAssertFalse(body.contains("NewInternalClient"))
        XCTAssertNil(UPnPRouterProtocol.request(service,action:.delete,externalPort:0))
    }
    func testInvalidClientPortLeaseAndForgedOriginCannotBuildRequest() {
        for client in ["example.invalid","0.0.0.0","192.0.2.10<injection>"] { XCTAssertNil(UPnPRouterProtocol.request(service,action:.add,internalClient:client,internalPort:47830,externalPort:47830)) }
        XCTAssertNil(UPnPRouterProtocol.request(service,action:.add,internalClient:gateway,internalPort:0,externalPort:47830))
        XCTAssertNil(UPnPRouterProtocol.request(service,action:.add,internalClient:gateway,internalPort:47830,externalPort:0))
        XCTAssertNil(UPnPRouterProtocol.request(service,action:.add,internalClient:gateway,internalPort:47830,externalPort:47830,leaseSeconds:0))
        XCTAssertNil(UPnPRouterProtocol.request(service,action:.add,internalClient:gateway,internalPort:47830,externalPort:47830,leaseSeconds:604801))
        let forged=UPnPRouterService(kind:.ip2,controlURL:URL(string:"http://example.invalid/control")!,gatewayAddress:gateway)
        XCTAssertNil(UPnPRouterProtocol.request(forged,action:.externalIP))
    }
    func testPppAndIp1PermanentLeaseIsExplicitButIp2RefusesIt() {
        for kind: UPnPRouterService.Kind in [.ip1,.ppp1] {
            let legacy=UPnPRouterService(kind:kind,controlURL:service.controlURL,gatewayAddress:gateway)
            XCTAssertNotNil(UPnPRouterProtocol.request(legacy,action:.add,internalClient:gateway,internalPort:47830,externalPort:47830,leaseSeconds:0))
        }
    }
    func testMatchingSuccessfulAddDeleteAndExternalIpResponses() {
        XCTAssertEqual(UPnPRouterProtocol.reply(response(.add),status:200,service:service,action:.add),.success(externalAddress:nil))
        XCTAssertEqual(UPnPRouterProtocol.reply(response(.delete),status:200,service:service,action:.delete),.success(externalAddress:nil))
        XCTAssertEqual(UPnPRouterProtocol.reply(response(.externalIP,contents:"<NewExternalIPAddress>100.100.0.1</NewExternalIPAddress>"),status:200,service:service,action:.externalIP),.success(externalAddress:"100.100.0.1"))
        if let request = UPnPRouterProtocol.request(service,action:.externalIP) {
            XCTAssertTrue(String(data:request.body,encoding:.utf8)!.contains("<u:GetExternalIPAddress"))
        } else { XCTFail("The external address action must have a request.") }
    }
    func testFaultsCannotBecomeSuccessEvenWhenHttpStatusIs200() {
        let fault=envelope("<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>718</errorCode><errorDescription>Conflict &amp; refused\nrequest</errorDescription></UPnPError></detail></s:Fault>")
        for status in [200,500] { XCTAssertEqual(UPnPRouterProtocol.reply(fault,status:status,service:service,action:.add),.fault(code:718,description:"Conflict & refused request")) }
    }
    func testWrongActionNamespaceStatusAndDuplicateArgumentRefused() {
        XCTAssertNil(UPnPRouterProtocol.reply(response(.delete),status:200,service:service,action:.add))
        XCTAssertNil(UPnPRouterProtocol.reply(response(.add,kind:.ip1),status:200,service:service,action:.add))
        XCTAssertNil(UPnPRouterProtocol.reply(response(.add),status:500,service:service,action:.add))
        XCTAssertNil(UPnPRouterProtocol.reply(response(.add),status:404,service:service,action:.add))
        let duplicate="<NewExternalIPAddress>203.0.113.7</NewExternalIPAddress><NewExternalIPAddress>203.0.113.8</NewExternalIPAddress>"
        XCTAssertNil(UPnPRouterProtocol.reply(response(.externalIP,contents:duplicate),status:200,service:service,action:.externalIP))
        XCTAssertNil(UPnPRouterProtocol.reply(envelope("<u:AddPortMappingResponse xmlns:u=\"\(service.kind.rawValue)\"/><u:AddPortMappingResponse xmlns:u=\"\(service.kind.rawValue)\"/>"),status:200,service:service,action:.add))
    }
    func testExternalIpReplyMustBeUsableAndSoapMustBeBoundedXml() {
        for address in ["127.0.0.1","224.0.0.1","0.0.0.0","example.invalid"] { XCTAssertNil(UPnPRouterProtocol.reply(response(.externalIP,contents:"<NewExternalIPAddress>\(address)</NewExternalIPAddress>"),status:200,service:service,action:.externalIP)) }
        XCTAssertNil(UPnPRouterProtocol.reply(Data(repeating:32,count:UPnPRouterProtocol.maximumSOAPBytes+1),status:200,service:service,action:.add))
        XCTAssertNil(UPnPRouterProtocol.reply(Data("<!DOCTYPE x [<!ENTITY x 'expanded'>]>".utf8)+response(.add),status:200,service:service,action:.add))
        XCTAssertNil(UPnPRouterProtocol.reply(Data("not xml".utf8),status:200,service:service,action:.add))
    }
    func testEachWanFamilyUsesItsOwnNamespaceForAddressAndAddActions() {
        for kind in UPnPRouterService.Kind.allCases {
            let owner=UPnPRouterService(kind:kind,controlURL:service.controlURL,gatewayAddress:gateway)
            XCTAssertNotNil(UPnPRouterProtocol.request(owner,action:.externalIP))
            XCTAssertEqual(UPnPRouterProtocol.reply(response(.add,kind:kind),status:200,service:owner,action:.add),.success(externalAddress:nil))
            XCTAssertEqual(UPnPRouterProtocol.reply(response(.externalIP,contents:"<NewExternalIPAddress>203.0.113.7</NewExternalIPAddress>",kind:kind),status:200,service:owner,action:.externalIP),.success(externalAddress:"203.0.113.7"))
        }
    }
}
