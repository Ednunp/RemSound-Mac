import Foundation

extension ProductTestPack {
    static let controlSpecifications = "Every control is specified (no control escapes the suite)"
    static func checkControlSpecifications(native: (() -> (assertions: Int, failures: [String])?)?) -> Step {
        guard let receipt = native?() else {
            return .init(name: controlSpecifications, status: "UNVERIFIED", assertions: 0,
                failures: ["actual-native-main-window-control-census-required"])
        }
        let punctuation = Set(".-[]".utf8)
        guard (1...4096).contains(receipt.assertions), receipt.failures.count <= 256,
            receipt.failures.allSatisfy({ $0.hasPrefix("controls.native.") && $0.utf8.count <= 128 &&
                $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || punctuation.contains($0) } }) else {
            return .init(name: controlSpecifications, status: "FAIL", assertions: 0, failures: ["controls.native.invalid-receipt"])
        }
        return .init(name: controlSpecifications, status: receipt.failures.isEmpty ? "PASS" : "FAIL",
            assertions: receipt.assertions, failures: receipt.failures)
    }
}
