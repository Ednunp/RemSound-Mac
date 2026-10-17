import Foundation
import XCTest
@testable import RemSoundCore

final class UPnPPreflightTests: XCTestCase {
    private let service = UPnPRouterService(kind: .ip2, controlURL: URL(string: "http://192.0.2.1/control")!, gatewayAddress: "192.0.2.1")
    private let fields = "<NewInternalPort>47830</NewInternalPort><NewInternalClient>192.0.2.10</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>Manual rule</NewPortMappingDescription><NewLeaseDuration>3600</NewLeaseDuration>"
    private func reply(_ fields: String) -> UPnPSOAPReply? {
        let xml = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:GetSpecificPortMappingEntryResponse xmlns:u=\"\(service.kind.rawValue)\">\(fields)</u:GetSpecificPortMappingEntryResponse></s:Body></s:Envelope>"
        return UPnPRouterProtocol.reply(Data(xml.utf8), status: 200, service: service, action: .specificMapping)
    }
    func testSpecificRequestUsesExactExternalUdpTupleWithoutMutation() throws {
        let request = try XCTUnwrap(UPnPRouterProtocol.request(service, action: .specificMapping, externalPort: 49321))
        XCTAssertTrue(String(decoding: request.body, as: UTF8.self).contains("<NewRemoteHost></NewRemoteHost><NewExternalPort>49321</NewExternalPort><NewProtocol>UDP</NewProtocol>"))
        XCTAssertTrue(request.soapAction.hasSuffix("#GetSpecificPortMappingEntry\""))
        XCTAssertNil(UPnPRouterProtocol.request(service, action: .specificMapping, externalPort: 0))
    }
    func testMappingReturnsAllFieldsIncludingPermanentAndDisabledRules() {
        XCTAssertEqual(reply(fields), .mapping(.init(internalPort: 47830, internalClient: "192.0.2.10", enabled: true, description: "Manual rule", leaseSeconds: 3600)))
        XCTAssertEqual(reply(fields.replacingOccurrences(of: ">1<", with: ">0<").replacingOccurrences(of: ">3600<", with: ">0<")), .mapping(.init(internalPort: 47830, internalClient: "192.0.2.10", enabled: false, description: "Manual rule", leaseSeconds: 0)))
    }
    func testMissingDuplicateExtraAndWrongNamespaceAreRejected() {
        for invalid in [fields.replacingOccurrences(of: "<NewEnabled>1</NewEnabled>", with: ""), fields + "<NewEnabled>1</NewEnabled>", fields + "<Other>value</Other>", fields.replacingOccurrences(of: "<NewEnabled>", with: "<NewEnabled xmlns=\"urn:wrong\">"), fields + "unexpected"] { XCTAssertNil(reply(invalid)) }
    }
    func testBadNumbersAddressesBooleansAndDescriptionAreRejected() {
        for (old, bad) in [("47830", "0"), ("47830", "65536"), ("47830", "047830"), ("192.0.2.10", "router.invalid"), ("192.0.2.10", "127.0.0.1"), (">1<", ">maybe<"), ("3600", "4294967296"), ("Manual rule", String(repeating: "x", count: 257)), ("Manual rule", "bad&#10;rule")] { XCTAssertNil(reply(fields.replacingOccurrences(of: old, with: bad)), bad) }
    }
    func testUpnpBooleanSpellingsAndMaximumLeaseAreRetained() {
        for value in ["1", "true", "yes", "0", "false", "no"] {
            let changed = fields.replacingOccurrences(of: "<NewEnabled>1</NewEnabled>", with: "<NewEnabled>\(value)</NewEnabled>").replacingOccurrences(of: ">3600<", with: ">4294967295<")
            XCTAssertEqual(reply(changed), .mapping(.init(internalPort: 47830, internalClient: "192.0.2.10", enabled: ["1", "true", "yes"].contains(value), description: "Manual rule", leaseSeconds: UInt32.max)))
        }
    }
    func testOnlyNoSuchEntryAllowsFreshCreation() {
        XCTAssertEqual(UPnPRouterProtocol.preflight(.fault(code: 714, description: "No entry")), .available)
        for code: UInt16 in [401, 606, 718, 725] { XCTAssertEqual(UPnPRouterProtocol.preflight(.fault(code: code, description: "Refused")), .unavailable) }
        XCTAssertEqual(UPnPRouterProtocol.preflight(nil), .unavailable)
        XCTAssertEqual(UPnPRouterProtocol.preflight(.success(externalAddress: nil)), .unavailable)
        let mapping = UPnPPortMapping(internalPort: 47830, internalClient: "192.0.2.10", enabled: true, description: "RemSound audio", leaseSeconds: 3600)
        XCTAssertEqual(UPnPRouterProtocol.preflight(.mapping(mapping)), .occupied(mapping))
    }
    func testDescriptionWhitespaceIsPreservedForExactOwnershipMatching() {
        let altered = fields.replacingOccurrences(of: "Manual rule", with: " Manual rule ")
        XCTAssertEqual(reply(altered), .mapping(.init(internalPort: 47830, internalClient: "192.0.2.10", enabled: true, description: " Manual rule ", leaseSeconds: 3600)))
        XCTAssertNil(reply(fields.replacingOccurrences(of: "Manual rule", with: "&#10;Manual rule")))
    }
    func testAllWanServiceFamiliesReturnSpecificMapping() {
        for kind in UPnPRouterService.Kind.allCases {
            let owner = UPnPRouterService(kind: kind, controlURL: service.controlURL, gatewayAddress: service.gatewayAddress)
            let body = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:GetSpecificPortMappingEntryResponse xmlns:u=\"\(kind.rawValue)\">\(fields)</u:GetSpecificPortMappingEntryResponse></s:Body></s:Envelope>"
            XCTAssertNotNil(UPnPRouterProtocol.request(owner, action: .specificMapping, externalPort: 47830))
            guard case .mapping? = UPnPRouterProtocol.reply(Data(body.utf8), status: 200, service: owner, action: .specificMapping) else { XCTFail("Expected typed mapping for \(kind)"); continue }
        }
    }
}
