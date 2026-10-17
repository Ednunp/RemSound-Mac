import Foundation

extension ProductTestPack {
    static let eventClaims = "Every wired event is claimed (no handler escapes the suites)"
    static func checkEventClaims(native: (() -> (assertions: Int, failures: [String])?)?) -> Step {
        guard let receipt = native?() else {
            return .init(name: eventClaims, status: "UNVERIFIED", assertions: 0, failures: ["actual-isolated-native-event-source-required"])
        }
        let punctuation = Set(".-".utf8)
        guard (1...8192).contains(receipt.assertions), receipt.failures.count <= 256,
            receipt.failures.allSatisfy({ $0.hasPrefix("events.native.") && $0.utf8.count <= 160 &&
                $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || punctuation.contains($0) } }) else {
            return .init(name: eventClaims, status: "FAIL", assertions: 0, failures: ["events.native.invalid-receipt"])
        }
        let pendingOnly = receipt.failures.allSatisfy { $0.hasPrefix("events.native.unverified-driver-") }
        return .init(name: eventClaims, status: receipt.failures.isEmpty ? "PASS" : pendingOnly ? "UNVERIFIED" : "FAIL",
            assertions: receipt.assertions, failures: receipt.failures)
    }
}
