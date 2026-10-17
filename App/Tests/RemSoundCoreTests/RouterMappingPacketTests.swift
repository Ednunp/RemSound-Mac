import Foundation
import XCTest
@testable import RemSoundCore

final class RouterMappingPacketTests: XCTestCase {
    private let gateway = Endpoint("192.0.2.1", 5351)
    private let nonce = Data(0..<12)
    private func natMap(code: UInt16 = 0, port: UInt16 = 47830, external: UInt16 = 49321, lifetime: UInt32 = 3600) -> Data {
        Data([0,129,UInt8(code >> 8),UInt8(code & 255),0,0,0,7,UInt8(port >> 8),UInt8(port & 255),UInt8(external >> 8),UInt8(external & 255),UInt8(lifetime >> 24),UInt8((lifetime >> 16) & 255),UInt8((lifetime >> 8) & 255),UInt8(lifetime & 255)])
    }
    private func pcpMap(code: UInt8 = 0, lifetime: UInt32 = 3600) -> Data {
        var b = [UInt8](repeating: 0, count: 60)
        b[0]=2; b[1]=129; b[3]=code
        b[4]=UInt8(lifetime >> 24); b[5]=UInt8((lifetime >> 16) & 255); b[6]=UInt8((lifetime >> 8) & 255); b[7]=UInt8(lifetime & 255)
        b[11]=7; b.replaceSubrange(24..<36, with: nonce); b[36]=17
        b[40]=0xba; b[41]=0xd6; b[42]=0xc0; b[43]=0xa9
        b[54]=255; b[55]=255; b[56]=203; b[57]=0; b[58]=113; b[59]=7
        return Data(b)
    }
    private func parsePcp(_ data: Data, nonce: Data? = nil, from: Endpoint? = nil, deleting: Bool = false) -> RouterMappingReply? {
        RouterMappingPackets.pcpMapReply(data, from: from ?? gateway, gateway: gateway, nonce: nonce ?? self.nonce, internalPort: 47830, deleting: deleting)
    }
    func testNatRequestHasNetworkOrderUdpPortsAndHourLifetime() {
        XCTAssertEqual(RouterMappingPackets.natAddressRequest(), Data([0,0]))
        XCTAssertEqual(RouterMappingPackets.natMapRequest(internalPort: 47830, suggestedPort: 49321, lifetime: 3600), Data([0,1,0,0,0xba,0xd6,0xc0,0xa9,0,0,14,16]))
    }
    func testNatDeletionZerosSuggestedPortAndCannotDeleteAllMappings() {
        XCTAssertEqual(RouterMappingPackets.natMapRequest(internalPort: 47830, suggestedPort: 49321, lifetime: 0), Data([0,1,0,0,0xba,0xd6,0,0,0,0,0,0]))
        XCTAssertNil(RouterMappingPackets.natMapRequest(internalPort: 0, suggestedPort: 47830, lifetime: 0))
        XCTAssertNil(RouterMappingPackets.natMapRequest(internalPort: 0, suggestedPort: 0, lifetime: 3600))
    }
    func testNatAddressReplyPreservesEpochAndAddress() {
        let data = Data([0,128,0,0,0,0,0,7,203,0,113,7])
        let value = RouterMappingPackets.natAddressReply(data, from: gateway, gateway: gateway)
        XCTAssertEqual(value?.externalAddress, "203.0.113.7"); XCTAssertEqual(value?.epoch, 7); XCTAssertEqual(value?.resultCode, 0)
    }
    func testNatMapReplyUsesActualGrantedPortAndLifetime() {
        let value = RouterMappingPackets.natMapReply(natMap(lifetime: 120), from: gateway, gateway: gateway, internalPort: 47830)
        XCTAssertEqual(value?.externalPort, 49321); XCTAssertEqual(value?.lifetime, 120); XCTAssertEqual(value?.epoch, 7)
    }
    func testNatOnlyExpectedGatewayAndInternalPortCanMatch() {
        for source in [Endpoint("192.0.2.2",5351),Endpoint("192.0.2.1",5350)] {
            XCTAssertNil(RouterMappingPackets.natMapReply(natMap(), from: source, gateway: gateway, internalPort: 47830))
            XCTAssertNil(RouterMappingPackets.natAddressReply(Data([0,128,0,0,0,0,0,7,203,0,113,7]), from: source, gateway: gateway))
        }
        XCTAssertNil(RouterMappingPackets.natMapReply(natMap(port: 47831), from: gateway, gateway: gateway, internalPort: 47830))
    }
    func testNatTruncationsExtraBytesVersionsAndWrongOpcodeRefused() {
        let data = natMap()
        for n in 0..<data.count { XCTAssertNil(RouterMappingPackets.natMapReply(Data(data.prefix(n)), from: gateway, gateway: gateway, internalPort: 47830)) }
        for byte in [0,1] {
            var changed=data; changed[byte] = byte == 0 ? 2 : 130
            XCTAssertNil(RouterMappingPackets.natMapReply(changed, from: gateway, gateway: gateway, internalPort: 47830))
        }
        XCTAssertNil(RouterMappingPackets.natMapReply(data + Data([0]), from: gateway, gateway: gateway, internalPort: 47830))
    }
    func testNatRefusalAndShortUnsupportedVersionHaveNoEndpoint() {
        let refused = RouterMappingPackets.natMapReply(natMap(code: 2,external: 0,lifetime: 0), from: gateway, gateway: gateway, internalPort: 47830)
        XCTAssertEqual(refused?.resultCode, 2); XCTAssertNil(refused?.externalAddress)
        let unsupported = RouterMappingPackets.natMapReply(Data([0,129,0,1,0,0,0,7]), from: gateway, gateway: gateway, internalPort: 47830)
        XCTAssertEqual(unsupported?.resultCode, 1); XCTAssertEqual(unsupported?.externalPort, 0)
    }
    func testNatDeleteAcknowledgmentCannotBecomeLiveMapping() {
        let data = natMap(external: 0,lifetime: 0)
        XCTAssertNil(RouterMappingPackets.natMapReply(data, from: gateway, gateway: gateway, internalPort: 47830))
        XCTAssertEqual(RouterMappingPackets.natMapReply(data, from: gateway, gateway: gateway, internalPort: 47830,deleting: true)?.lifetime, 0)
        XCTAssertNil(RouterMappingPackets.natMapReply(natMap(), from: gateway, gateway: gateway, internalPort: 47830,deleting: true))
    }
    func testNatAddressRejectsUnusableSuccessAndPreservesErrors() {
        for ip: [UInt8] in [[0,0,0,0],[127,0,0,1],[224,0,0,1],[255,255,255,255]] {
            XCTAssertNil(RouterMappingPackets.natAddressReply(Data([0,128,0,0,0,0,0,7]+ip), from: gateway, gateway: gateway))
        }
        XCTAssertEqual(RouterMappingPackets.natAddressReply(Data([0,128,0,3,0,0,0,7,0,0,0,0]),from:gateway,gateway:gateway)?.resultCode,3)
    }
    func testPcpRequestIsIpv4MappedMapWithNonceAndUdp() throws {
        let data = try XCTUnwrap(RouterMappingPackets.pcpMapRequest(clientAddress: "192.0.2.10",nonce:nonce,internalPort:47830,suggestedPort:49321,lifetime:3600))
        XCTAssertEqual(data.count,60); XCTAssertEqual(Array(data.prefix(8)),[2,1,0,0,0,0,14,16])
        XCTAssertEqual(Array(data[8..<24]),[0,0,0,0,0,0,0,0,0,0,255,255,192,0,2,10])
        XCTAssertEqual(Data(data[24..<36]),nonce); XCTAssertEqual(Array(data[36..<44]),[17,0,0,0,0xba,0xd6,0xc0,0xa9])
        XCTAssertEqual(Data(data[44..<60]),Data(repeating:0,count:16))
    }
    func testPcpDeletionKeepsNonceAndCannotDeleteAllMappings() throws {
        let data = try XCTUnwrap(RouterMappingPackets.pcpMapRequest(clientAddress:"192.0.2.10",nonce:nonce,internalPort:47830,suggestedPort:49321,lifetime:0,suggestedAddress:"203.0.113.7"))
        XCTAssertEqual(Data(data[24..<36]),nonce); XCTAssertEqual(Data(data[4..<8]),Data(repeating:0,count:4))
        XCTAssertEqual(Array(data[36..<44]),[17,0,0,0,0xba,0xd6,0xc0,0xa9])
        XCTAssertNil(RouterMappingPackets.pcpMapRequest(clientAddress:"192.0.2.10",nonce:nonce,internalPort:0,suggestedPort:0,lifetime:0))
    }
    func testPcpBuilderRejectsBadClientSuggestionAndNonce() {
        for address in ["", "192.0.2.999", "192.00.2.10", "::1", "0.0.0.0", "224.0.0.1"] {
            XCTAssertNil(RouterMappingPackets.pcpMapRequest(clientAddress:address,nonce:nonce,internalPort:47830,suggestedPort:47830,lifetime:3600))
        }
        for size in [0,11,13,100] {
            XCTAssertNil(RouterMappingPackets.pcpMapRequest(clientAddress:"192.0.2.10",nonce:Data(repeating:0,count:size),internalPort:47830,suggestedPort:47830,lifetime:3600))
        }
        XCTAssertNil(RouterMappingPackets.pcpMapRequest(clientAddress:"192.0.2.10",nonce:nonce,internalPort:47830,suggestedPort:47830,lifetime:3600,suggestedAddress:"example.invalid"))
    }
    func testPcpReplyPreservesActualEndpointLeaseEpochAndReservedFieldsAreIgnored() {
        var data=pcpMap(lifetime:120); data[2]=255;data[12]=255;data[37]=255
        let value=parsePcp(data)
        XCTAssertEqual(value?.externalAddress,"203.0.113.7");XCTAssertEqual(value?.externalPort,49321)
        XCTAssertEqual(value?.lifetime,120);XCTAssertEqual(value?.epoch,7)
    }
    func testPcpRefusesDifferentNonceProtocolAndInternalPort() {
        for offset in [24,35,36,40,41] {
            var data=pcpMap();data[offset] ^= 1;XCTAssertNil(parsePcp(data),"offset \(offset)")
        }
        XCTAssertNil(parsePcp(pcpMap(),nonce:Data(repeating:0,count:11)))
    }
    func testPcpRefusesWrongSourceVersionOpcodeAndTruncations() {
        let data=pcpMap()
        XCTAssertNil(parsePcp(data,from:Endpoint("192.0.2.2",5351)));XCTAssertNil(parsePcp(data,from:Endpoint("192.0.2.1",5350)))
        for n in 0..<data.count { XCTAssertNil(parsePcp(Data(data.prefix(n)))) }
        for offset in [0,1] { var changed=data;changed[offset] ^= 1;XCTAssertNil(parsePcp(changed)) }
    }
    func testPcpErrorsRetainRetryLifetimeWithoutAdvertisingEndpoint() {
        let value=parsePcp(pcpMap(code:8,lifetime:120))
        XCTAssertEqual(value?.resultCode,8);XCTAssertEqual(value?.lifetime,120);XCTAssertNil(value?.externalAddress)
    }
    func testPcpZeroLifetimeOnlyMatchesDeletionAndIpv6IsOutsideCurrentAudioScope() {
        XCTAssertNil(parsePcp(pcpMap(lifetime:0)))
        XCTAssertEqual(parsePcp(pcpMap(lifetime:0),deleting:true)?.lifetime,0)
        XCTAssertEqual(parsePcp(pcpMap(),deleting:true)?.lifetime,3600)
        var ipv6=pcpMap();ipv6[44]=0x20;ipv6[45]=1;XCTAssertNil(parsePcp(ipv6))
    }
    func testPcpDeletionReplyCanRetainOutboundMappingLifetime() {
        let value = parsePcp(pcpMap(lifetime: 30), deleting: true)
        XCTAssertEqual(value?.lifetime, 30); XCTAssertEqual(value?.externalPort, 49321); XCTAssertEqual(value?.externalAddress, "203.0.113.7")
    }
    func testPcpUnknownResponseOptionsIgnoredButMalformedLengthsRefused() {
        let data=pcpMap()
        XCTAssertNotNil(parsePcp(data+Data([1,255,0,1,7,0,0,0,128,0,0,0])))
        for tail in [Data([128]),Data([128,0,0,1]),Data([128,0,255,255]),Data(repeating:0,count:1044)] { XCTAssertNil(parsePcp(data+tail)) }
    }
    func testSlicedDataAndZeroNonceAreSupportedWithoutUnsafeIndexing() throws {
        let nat=Data([99])+natMap(), pcp=Data([99])+pcpMap()
        XCTAssertEqual(RouterMappingPackets.natMapReply(nat.dropFirst(),from:gateway,gateway:gateway,internalPort:47830)?.externalPort,49321)
        XCTAssertEqual(parsePcp(pcp.dropFirst())?.externalPort,49321)
        let zero=Data(repeating:0,count:12)
        XCTAssertNotNil(RouterMappingPackets.pcpMapRequest(clientAddress:"192.0.2.10",nonce:zero,internalPort:47830,suggestedPort:0,lifetime:UInt32.max))
        var data=pcpMap();data.replaceSubrange(24..<36,with:zero);XCTAssertNotNil(parsePcp(data,nonce:zero))
    }
}
