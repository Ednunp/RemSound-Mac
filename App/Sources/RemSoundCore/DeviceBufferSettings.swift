import Foundation

// Core Audio buffer sizes belong to the device, so restore only settings we
// still own. A later change by another audio application must survive Stop.
final class DeviceBufferSettings {
    private var saved: [UInt32: (original: UInt32, applied: UInt32)] = [:]
    private let read: (UInt32) -> UInt32?
    private let write: (UInt32, UInt32) -> Bool

    init(read: @escaping (UInt32) -> UInt32?, write: @escaping (UInt32, UInt32) -> Bool) {
        self.read = read
        self.write = write
    }

    @discardableResult
    func apply(device: UInt32, frames: UInt32) -> Bool {
        guard let before = read(device), write(device, frames) else { return false }
        let previous = saved[device]
        let original = previous?.applied == before ? previous!.original : before
        saved[device] = (original, read(device) ?? frames)
        return true
    }

    @discardableResult
    func restore() -> [UInt32] {
        var failed: [UInt32] = []
        for (device, value) in saved {
            guard let current = read(device) else { failed.append(device); continue }
            if current == value.applied && current != value.original {
                guard write(device, value.original), read(device) == value.original else {
                    failed.append(device)
                    continue
                }
            }
            saved.removeValue(forKey: device)
        }
        return failed.sorted()
    }
}
