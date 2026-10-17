import Foundation

enum IsolatedTestDirectory {
    enum Failure: Error { case missingRoot, invalidRoot }

    static func root(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        guard let path = environment["REMSOUND_TEST_ROOT"], !path.isEmpty else {
            throw Failure.missingRoot
        }
        guard (path as NSString).isAbsolutePath else { throw Failure.invalidRoot }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root.path != "/", root.path != NSHomeDirectory(),
            root.resolvingSymlinksInPath().path == root.path,
            (try? FileManager.default.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType) == .typeDirectory
        else { throw Failure.invalidRoot }
        return root
    }

    static func make(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            throw Failure.invalidRoot
        }
        let directory = try root(environment: environment)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory
    }
}

