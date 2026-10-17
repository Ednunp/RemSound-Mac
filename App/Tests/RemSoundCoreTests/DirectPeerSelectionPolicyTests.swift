import Foundation
import XCTest
@testable import RemSoundCore

final class DirectPeerSelectionPolicyTests: XCTestCase {
    private let old = Endpoint("192.0.2.1", 54321)
    private let new = Endpoint("192.0.2.2", 54322)
    private let id = UUID()
    private func discovery(_ endpoint: Endpoint, at time: TimeInterval = 100, id: UUID? = nil,
                           name: String = "Studio") -> DirectPeerSelectionPolicy.Discovery {
        .init(instanceID: id ?? self.id, endpoint: endpoint, name: name, seen: time)
    }

    func testSameEndpointBindsManualIdentityWithoutMovingThePort() {
        var policy = DirectPeerSelectionPolicy()
        let result = policy.resolve(instanceID: nil, typedEntry: old.address, pinned: old,
            pinResponds: false, discovered: [discovery(old)], locked: false, now: 100)
        XCTAssertEqual(result?.instanceID, id)
        XCTAssertEqual(result?.endpoint, old)
    }

    func testUnansweredTypedNameCorrectsStaleDNSOnce() {
        var policy = DirectPeerSelectionPolicy()
        let result = policy.resolve(instanceID: nil, typedEntry: " Studio:54321 ", pinned: old,
            pinResponds: false, discovered: [discovery(new)], locked: false, now: 100)
        XCTAssertEqual(result?.endpoint, new)
        XCTAssertEqual(result?.instanceID, id)
    }

    func testWorkingTypedNameBindsIdentityButPreservesUserChosenEndpoint() {
        var policy = DirectPeerSelectionPolicy()
        let result = policy.resolve(instanceID: nil, typedEntry: "studio", pinned: old,
            pinResponds: true, discovered: [discovery(new)], locked: false, now: 100)
        XCTAssertEqual(result?.endpoint, old)
        XCTAssertEqual(result?.instanceID, id)
    }

    func testDuplicateNamesFromDistinctInstancesNeverBindByName() {
        var policy = DirectPeerSelectionPolicy()
        XCTAssertNil(policy.resolve(instanceID: nil, typedEntry: "Studio", pinned: old,
            pinResponds: false, discovered: [discovery(new),discovery(Endpoint("192.0.2.3"),id:UUID(),name:"STUDIO")],
            locked:false,now:100))
    }

    func testDualAddressesOfOneInstanceAreNotANameCollision() {
        var policy = DirectPeerSelectionPolicy()
        XCTAssertEqual(policy.resolve(instanceID:nil,typedEntry:"Studio",pinned:old,pinResponds:false,
            discovered:[discovery(new,at:99),discovery(Endpoint("192.0.2.3"),at:100)],locked:false,now:100)?.endpoint,
            Endpoint("192.0.2.3"))
    }

    func testDiscoveredIdentityNeverFollowsAnotherInstanceWithSameName() {
        var policy = DirectPeerSelectionPolicy()
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:"Studio",pinned:old,pinResponds:false,
            discovered:[discovery(new,id:UUID())],locked:false,now:100))
    }

    func testNumericManualAddressIsNotFollowedByAdvertisedName() {
        var policy = DirectPeerSelectionPolicy()
        XCTAssertNil(policy.resolve(instanceID:nil,typedEntry:old.address,pinned:old,pinResponds:false,
            discovered:[discovery(new,name:old.address)],locked:false,now:100))
    }

    func testAddressLockDisablesExactMergeNameBindingAndFollowing() {
        var policy = DirectPeerSelectionPolicy()
        for (identity, entry, endpoint) in [(nil,old.address,old),(nil,"Studio",new),(Optional(id),"Studio",new)] {
            XCTAssertNil(policy.resolve(instanceID:identity,typedEntry:entry,pinned:old,pinResponds:false,
                discovered:[discovery(endpoint)],locked:true,now:100))
        }
    }

    func testHealthyPinNeverMovesAndResetsUnreachableGrace() {
        var policy = DirectPeerSelectionPolicy()
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new)],locked:false,now:100))
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:true,
            discovered:[discovery(new,at:106)],locked:false,now:106))
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new,at:107)],locked:false,now:107))
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new,at:112)],locked:false,now:112))
        XCTAssertEqual(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new,at:113)],locked:false,now:113)?.endpoint,new)
    }

    func testFollowRequiresSixSecondsOutageAndFreshCandidateProof() {
        var policy = DirectPeerSelectionPolicy()
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new)],locked:false,now:100))
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new,at:105.9)],locked:false,now:105.9))
        XCTAssertEqual(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new,at:106)],locked:false,now:106)?.endpoint,new)
    }

    func testExpiredAndFutureCandidatesNeverCauseMovement() {
        var policy = DirectPeerSelectionPolicy()
        XCTAssertNil(policy.resolve(instanceID:nil,typedEntry:"Studio",pinned:old,pinResponds:false,
            discovered:[discovery(new,at:90)],locked:false,now:100))
        XCTAssertNil(policy.resolve(instanceID:nil,typedEntry:"Studio",pinned:old,pinResponds:false,
            discovered:[discovery(new,at:101)],locked:false,now:100))
    }

    func testFifteenSecondCooldownPreventsAlternatingRouteThrash() {
        var policy = DirectPeerSelectionPolicy()
        XCTAssertEqual(policy.resolve(instanceID:nil,typedEntry:"Studio",pinned:old,pinResponds:false,
            discovered:[discovery(new)],locked:false,now:100)?.endpoint,new)
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:new,pinResponds:false,
            discovered:[discovery(old,at:101)],locked:false,now:101))
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:new,pinResponds:false,
            discovered:[discovery(old,at:107)],locked:false,now:107))
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:new,pinResponds:false,
            discovered:[discovery(old,at:114.9)],locked:false,now:114.9))
        XCTAssertEqual(policy.resolve(instanceID:id,typedEntry:nil,pinned:new,pinResponds:false,
            discovered:[discovery(old,at:115)],locked:false,now:115)?.endpoint,old)
    }

    func testLockWindowAndExplicitDeselectionResetOutageState() {
        var policy = DirectPeerSelectionPolicy()
        _ = policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new)],locked:false,now:100)
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new,at:110)],locked:true,now:110))
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new,at:111)],locked:false,now:111))
        policy.forget(id)
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new,at:117)],locked:false,now:117))
    }

    func testSameEndpointAnnouncementRestartsGraceAndResetDropsPriorHistory() {
        var policy = DirectPeerSelectionPolicy()
        _ = policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new)],locked:false,now:100)
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(old,at:106)],locked:false,now:106))
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new,at:107)],locked:false,now:107))
        policy.reset()
        XCTAssertNil(policy.resolve(instanceID:id,typedEntry:nil,pinned:old,pinResponds:false,
            discovered:[discovery(new,at:120)],locked:false,now:120))
    }
}
