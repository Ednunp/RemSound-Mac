#if DEBUG
import Foundation

enum HeadlessPeerMoveCheckPolicy {
    static func accepts(root: URL?, headless: Bool, silent: Bool, environment: [String: String]) -> Bool {
        guard environment["REMSOUND_TEST_PEER_MOVE_CHECK"] == "1", headless, silent,
            let root, let testPath = environment["REMSOUND_TEST_ROOT"],
            testPath.hasPrefix("/"), testPath != "/" else { return false }
        let testRoot = URL(fileURLWithPath: testPath).standardizedFileURL.path
        let configurationRoot = root.standardizedFileURL.path
        return testRoot != "/" && configurationRoot.hasPrefix(testRoot + "/")
    }
}
#endif
