import XCTest
@testable import RemSoundCore

final class NetworkRouteTests: XCTestCase {
    func testLoopbackRouteIdentifiesInterfaceWithoutSendingADatagram() throws {
        let receiver = try UDP(port: 0, loopback: true)
        let route = try XCTUnwrap(NetworkRoute.read(to: Endpoint("127.0.0.1", receiver.boundPort)))
        XCTAssertEqual(route.sourceAddress, "127.0.0.1")
        XCTAssertEqual(route.interface, "lo0")
        XCTAssertEqual(route.interfaceType, "Loopback")
        XCTAssertNil(receiver.receive(), "A route probe must not send payload or control packets")
    }

    func testMalformedDestinationHasNoInventedRoute() {
        XCTAssertNil(NetworkRoute.read(to: Endpoint("invalid address")))
    }
}
