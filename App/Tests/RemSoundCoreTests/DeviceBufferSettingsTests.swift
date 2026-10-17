import XCTest
@testable import RemSoundCore

final class DeviceBufferSettingsTests: XCTestCase {
    func testRestoresOriginalAfterSeveralSelectionsAndStop() {
        var devices: [UInt32: UInt32] = [1: 512, 2: 256]
        let settings = DeviceBufferSettings(read: { devices[$0] }, write: { devices[$0] = $1; return true })
        XCTAssertTrue(settings.apply(device: 1, frames: 64))
        XCTAssertTrue(settings.apply(device: 1, frames: 32))
        XCTAssertTrue(settings.apply(device: 2, frames: 128))
        settings.restore()
        XCTAssertEqual(devices, [1: 512, 2: 256])
    }

    func testDoesNotReplaceAnotherApplicationsChange() {
        var devices: [UInt32: UInt32] = [1: 512]
        let settings = DeviceBufferSettings(read: { devices[$0] }, write: { devices[$0] = $1; return true })
        XCTAssertTrue(settings.apply(device: 1, frames: 64))
        devices[1] = 128
        settings.restore()
        XCTAssertEqual(devices[1], 128)
    }

    func testRefusedOrUnreadableDeviceIsNeverChangedOnRestore() {
        let devices: [UInt32: UInt32] = [1: 512]
        var writes = 0
        let settings = DeviceBufferSettings(read: { devices[$0] }, write: { _, _ in writes += 1; return false })
        XCTAssertFalse(settings.apply(device: 1, frames: 64))
        XCTAssertFalse(settings.apply(device: 2, frames: 64))
        settings.restore()
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(devices[1], 512)
    }

    func testRestorationFailureCanBeRetried() {
        var devices: [UInt32: UInt32] = [1: 512]
        var acceptsWrites = true
        let settings = DeviceBufferSettings(read: { devices[$0] }, write: {
            guard acceptsWrites else { return false }
            devices[$0] = $1
            return true
        })
        XCTAssertTrue(settings.apply(device: 1, frames: 64))
        acceptsWrites = false
        XCTAssertEqual(settings.restore(), [1])
        acceptsWrites = true
        XCTAssertTrue(settings.restore().isEmpty)
        XCTAssertEqual(devices[1], 512)
    }
}
