import CryptoKit
import Darwin
import Foundation
import Security
import RemSoundRuntime

public struct PluginToolReceipt: Codable, Sendable {
    public let schema: Int
    public let generatedUTC: String
    public let action: String
    public let scope: String
    public let status: String
    public let payloadSource: String
    public let files: Int
    public let ignoredManifestEntries: Int
    public let nativeActivationVerified: Bool
}

/// The isolated command uses the real transaction. Normal package ownership is not established yet.
public enum PluginInstallationCommand {
    private static let locations = [
        ("AU/RemSound.component", "Components/RemSound.component"),
        ("VST3/RemSound.vst3", "VST3/RemSound.vst3"),
        ("CLAP/RemSound.clap", "CLAP/RemSound.clap")
    ]
    private static let targetPrefix = "Library/Audio/Plug-Ins/"
    private static let manifestName = "plugin-installation.json"
    private static let maximumFiles = 4096
    private static let maximumManifestBytes = 128 * 1024
    private static let maximumFileBytes = 32 * 1024 * 1024
    private static let maximumPayloadBytes = 128 * 1024 * 1024
    private struct Entry: Codable { let path: String; let sha256: String }
    private struct Manifest: Codable { let schema: Int; let files: [Entry] }
    private enum Failure: Error { case refused, missingPayload, notInstalled, recoveryRequired }

    public static func run(action: PluginToolAction, isolatedRoot: URL?) -> PluginToolReceipt {
        run(action: action, isolatedRoot: isolatedRoot, checkpoint: {})
    }
    static func run(action: PluginToolAction, isolatedRoot: URL?, checkpoint: () throws -> Void) -> PluginToolReceipt {
        var count = 0, ignored = 0
        var payloadSource = "none"
        func receipt(_ status: String) -> PluginToolReceipt {
            .init(schema: 1, generatedUTC: ISO8601DateFormatter().string(from: Date()), action: action.rawValue,
                scope: isolatedRoot == nil ? "user" : "isolated", status: status, payloadSource: payloadSource, files: count,
                ignoredManifestEntries: ignored, nativeActivationVerified: false)
        }
        // No normal location, source, signature, process or settings factory is consulted on refusal.
        guard let root = isolatedRoot else { return receipt("unsupported") }
        do {
            let gate = try RootGate(root)
            let lock = root.appendingPathComponent(".plugin-command.lock")
            let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Failure.refused }
            var ownedLock = stat()
            guard fstat(descriptor, &ownedLock) == 0 else { _ = Darwin.close(descriptor); throw Failure.refused }
            defer {
                _ = Darwin.close(descriptor)
                if let current = try? state(lock), current.st_dev == ownedLock.st_dev, current.st_ino == ownedLock.st_ino {
                    _ = unlink(lock.path)
                }
            }
            try gate.check()
            let manifestURL = root.appendingPathComponent(manifestName)
            let prior = try readManifest(manifestURL, gate: gate, ignored: &ignored)
            if action == .remove {
                guard let prior, !prior.isEmpty else { throw Failure.notInstalled }
                var targets = [URL](), expectedRemoval = [URL: String](), total = 0
                for entry in prior {
                    let url = try gate.url(entry.path)
                    guard let attributes = try state(url) else { continue }
                    total += Int(attributes.st_size)
                    guard total <= maximumPayloadBytes, try digest(url) == entry.sha256 else { throw Failure.refused }
                    targets.append(url)
                    expectedRemoval[url] = entry.sha256
                }
                expectedRemoval[manifestURL] = try digest(manifestURL, maximum: maximumManifestBytes)
                try UpdateTransaction.removeFiles(targets + [manifestURL], beforeMove: { url in
                    _ = try gate.url(String(url.path.dropFirst(root.path.count + 1)))
                    guard try digest(url, maximum: url == manifestURL ? maximumManifestBytes : maximumFileBytes) == expectedRemoval[url] else { throw Failure.refused }
                },
                    beforeCommit: { try gate.check(); try checkpoint() })
                for url in targets { pruneEmptyParents(of: url, root: root) }
                count = targets.count
                return receipt("removed")
            }
            let sealed = try sealedFixtureSource(gate: gate)
            payloadSource = sealed == nil ? "isolated-raw-payload" : "isolated-sealed-app"
            let priorByPath = Dictionary(uniqueKeysWithValues: (prior ?? []).map { ($0.path, $0.sha256) })
            var files = [(source: URL, entry: Entry)](), folded = Set<String>(), total = 0
            for (source, target) in locations {
                let sourceRoot = try gate.url(sealed.map { $0.prefix + "/" + String(source.split(separator: "/").last!) } ?? ("plugin-payload/" + source))
                guard let attributes = try state(sourceRoot) else { throw Failure.missingPayload }
                guard isDirectory(attributes) else { throw Failure.refused }
                var enumerationFailed = false, visited = 0, added = 0
                guard let iterator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil,
                    errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw Failure.refused }
                for case let url as URL in iterator {
                    visited += 1
                    guard visited <= maximumFiles * 2 else { throw Failure.refused }
                    let suffix = String(url.path.dropFirst(sourceRoot.path.count + 1))
                    guard validRelative(suffix), let item = try state(url) else { throw Failure.refused }
                    try gate.check()
                    if isDirectory(item) { continue }
                    guard isRegular(item), item.st_nlink == 1, item.st_size >= 0, item.st_size <= maximumFileBytes else { throw Failure.refused }
                    total += Int(item.st_size)
                    let relative = targetPrefix + target + "/" + suffix
                    guard total <= maximumPayloadBytes, files.count < maximumFiles,
                        folded.insert(relative.lowercased()).inserted else { throw Failure.refused }
                    _ = try gate.url(sealed.map { $0.prefix + "/" + String(source.split(separator: "/").last!) + "/" + suffix } ?? ("plugin-payload/" + source + "/" + suffix))
                    let destination = try gate.url(relative)
                    if try state(destination) != nil {
                        guard let old = priorByPath[relative], try digest(destination) == old else { throw Failure.refused }
                    }
                    let hash = try digest(url)
                    if let sealed {
                        let key = String(source.split(separator: "/").last!) + "/" + suffix
                        guard let expected = sealed.entries[key], expected.sha256 == hash,
                            expected.size == item.st_size, expected.mode == UInt32(item.st_mode & 0o777) else { throw Failure.refused }
                    }
                    files.append((url, .init(path: relative, sha256: hash)))
                    added += 1
                }
                guard !enumerationFailed, added > 0 else { throw Failure.missingPayload }
            }
            if let sealed {
                guard files.count == sealed.entries.count else { throw Failure.refused }
                try sealed.verify()
            }
            var entries = priorByPath
            for file in files { entries[file.entry.path] = file.entry.sha256 }
            guard entries.count <= maximumFiles else { throw Failure.refused }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Manifest(schema: 1, files: entries.keys.sorted().map { .init(path: $0, sha256: entries[$0]!) }))
            guard data.count <= maximumManifestBytes else { throw Failure.refused }
            let manifestStage = root.appendingPathComponent(".plugin-manifest-" + UUID().uuidString)
            try writeNew(data, to: manifestStage, mode: 0o600)
            defer { try? FileManager.default.removeItem(at: manifestStage) }
            let items = try files.map { UpdateInstallItem(source: $0.source, target: try gate.url($0.entry.path)) }
                + [UpdateInstallItem(source: manifestStage, target: manifestURL)]
            var expected = Dictionary(uniqueKeysWithValues: zip(items.dropLast(), files).map { ($0.0.target, $0.1.entry.sha256) })
            expected[manifestURL] = sha(data)
            var missingParents = Set<URL>()
            for item in items {
                var parent = item.target.deletingLastPathComponent()
                while parent.path != root.path {
                    if try state(parent) == nil { missingParents.insert(parent) }
                    parent.deleteLastPathComponent()
                }
            }
            do {
                var finalVerifications = 0
                try UpdateTransaction.install(items, copy: { source, target in
                    _ = try gate.url(String(target.path.dropFirst(root.path.count + 1)))
                    guard let attributes = try state(source) else { throw Failure.refused }
                    _ = try gate.url(String(source.path.dropFirst(root.path.count + 1)))
                    let bytes = try boundedRead(source, maximum: source == manifestStage ? maximumManifestBytes : maximumFileBytes)
                    try writeNew(bytes, to: target, mode: attributes.st_mode & 0o777)
                }, verify: { url in
                    _ = try gate.url(String(url.path.dropFirst(root.path.count + 1)))
                    let matches = items.filter {
                        $0.target == url || (url.path.hasPrefix($0.target.deletingPathExtension().path + ".new-") && url.pathExtension == $0.target.pathExtension)
                    }
                    guard matches.count == 1, let target = matches.first?.target,
                        try digest(url, maximum: target == manifestURL ? maximumManifestBytes : maximumFileBytes) == expected[target] else { throw Failure.refused }
                    if url == target {
                        finalVerifications += 1
                        if finalVerifications == items.count { try sealed?.verify(); try checkpoint() }
                    }
                })
            } catch {
                for url in missingParents.sorted(by: { $0.path.count > $1.path.count }) {
                    _ = rmdir(url.path)
                }
                throw error
            }
            count = files.count
            return receipt("installed")
        } catch Failure.missingPayload { return receipt("missingPayload") }
        catch Failure.notInstalled { return receipt("notInstalled") }
        catch Failure.refused { return receipt("refused") }
        catch Failure.recoveryRequired { return receipt("recoveryRequired") }
        catch is UpdateTransactionError { return receipt("recoveryRequired") }
        catch { return receipt("failed") }
    }

    private struct PayloadFile: Decodable { let path: String; let sha256: String; let size: Int64; let mode: UInt32 }
    private struct PayloadManifest: Decodable {
        let schema: Int; let appIdentifier: String; let version: String; let build: String
        let architectures: [String]; let files: [PayloadFile]
    }
    private struct SealedSource {
        let prefix: String
        let entries: [String: PayloadFile]
        let verify: () throws -> Void
    }
    // This source is an explicitly isolated fixture. Static seal validity is not Developer ID
    // authority; the normal command still refuses before consulting any source or signature.
    private static func sealedFixtureSource(gate: RootGate) throws -> SealedSource? {
        let relative = "plugin-source/RemSound.app"
        let app = try gate.url(relative)
        guard try state(app) != nil else { return nil }
        let prefix = relative + "/Contents/PlugIns"
        let info = try gate.url(relative + "/Contents/Info.plist")
        let manifestURL = try gate.url(relative + "/Contents/Resources/plugin-payload.json")
        let infoData = try boundedRead(info, maximum: maximumManifestBytes)
        let manifestData = try boundedRead(manifestURL, maximum: maximumManifestBytes)
        let manifest = try JSONDecoder().decode(PayloadManifest.self, from: manifestData)
        guard let metadata = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
            metadata["CFBundleIdentifier"] as? String == "org.remsound.mac", metadata["CFBundleExecutable"] as? String == "RemSound",
            metadata["CFBundleShortVersionString"] as? String == manifest.version,
            metadata["CFBundleVersion"] as? String == manifest.build,
            manifest.schema == 1, manifest.appIdentifier == "org.remsound.mac",
            !manifest.version.isEmpty, manifest.version.utf8.count <= 32, !manifest.build.isEmpty, manifest.build.utf8.count <= 10,
            manifest.architectures == ["arm64", "x86_64"], !manifest.files.isEmpty, manifest.files.count <= maximumFiles else { throw Failure.refused }
        var entries = [String: PayloadFile](), folded = Set<String>(), total: Int64 = 0
        let bundles = locations.map { String($0.0.split(separator: "/").last!) }
        for file in manifest.files {
            guard validRelative(file.path), bundles.contains(where: { file.path.hasPrefix($0 + "/") }),
                file.sha256.utf8.count == 64, file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                file.size >= 0, file.size <= maximumFileBytes, file.mode <= 0o777, file.mode & 0o022 == 0,
                folded.insert(file.path.lowercased()).inserted else { throw Failure.refused }
            total += file.size; guard total <= maximumPayloadBytes else { throw Failure.refused }
            entries[file.path] = file
        }
        let verify: () throws -> Void = {
            try gate.check()
            guard try boundedRead(info, maximum: maximumManifestBytes) == infoData,
                try boundedRead(manifestURL, maximum: maximumManifestBytes) == manifestData else { throw Failure.refused }
            try validateStaticSeal(app, identifier: "org.remsound.mac", gate: gate)
            guard universal64(try boundedRead(gate.url(relative + "/Contents/MacOS/RemSound"), maximum: maximumFileBytes), type: 2) else { throw Failure.refused }
            for name in bundles {
                let root = try gate.url(prefix + "/" + name)
                let data = try boundedRead(gate.url(prefix + "/" + name + "/Contents/Info.plist"), maximum: maximumManifestBytes)
                guard let plugin = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                    plugin["CFBundleIdentifier"] as? String == "org.remsound.plugin", plugin["CFBundleExecutable"] as? String == "RemSound",
                    plugin["CFBundleShortVersionString"] as? String == manifest.version else { throw Failure.refused }
                try validateStaticSeal(root, identifier: "org.remsound.plugin", gate: gate)
                guard universal64(try boundedRead(gate.url(prefix + "/" + name + "/Contents/MacOS/RemSound"), maximum: maximumFileBytes), type: 8),
                    universal64(try boundedRead(gate.url(prefix + "/" + name + "/Contents/Frameworks/libRemSoundPluginHost-v1.dylib"), maximum: maximumFileBytes), type: 6) else { throw Failure.refused }
            }
            try gate.check()
        }
        try verify()
        return .init(prefix: prefix, entries: entries, verify: verify)
    }
    private static func validateStaticSeal(_ url: URL, identifier: String, gate: RootGate) throws {
        try gate.check()
        var code: SecStaticCode?, requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSRestrictSymlinks | kSecCSSingleThreaded)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(("identifier \"" + identifier + "\"") as CFString, [], &requirement) == errSecSuccess, let requirement,
            SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw Failure.refused }
        try gate.check()
    }
    // The producer emits bounded two-slice fat32 Mach-O, not an arbitrary executable plan.
    private static func universal64(_ data: Data, type: UInt32) -> Bool {
        guard data.count >= 48 else { return false }
        func be(_ offset: Int) -> UInt32 { data[offset..<offset+4].reduce(0) { ($0 << 8) | UInt32($1) } }
        func le(_ offset: Int) -> UInt32 { data[offset..<offset+4].reversed().reduce(0) { ($0 << 8) | UInt32($1) } }
        guard be(0) == 0xcafebabe, be(4) == 2 else { return false }
        var cpus = Set<UInt32>(), ranges = [Range<Int>]()
        for index in 0..<2 {
            let base = 8 + index * 20, cpu = be(base), offset = Int(be(base+8)), size = Int(be(base+12)), alignment = be(base+16)
            guard [UInt32(0x0100000c), 0x01000007].contains(cpu), cpus.insert(cpu).inserted, alignment <= 30,
                offset >= 48, size >= 32, offset <= data.count, size <= data.count-offset, offset % (1 << alignment) == 0,
                le(offset) == 0xfeedfacf, le(offset+4) == cpu, le(offset+12) == type else { return false }
            let range = offset..<offset+size
            guard !ranges.contains(where: { $0.overlaps(range) }) else { return false }; ranges.append(range)
        }
        return true
    }

    private static func validRelative(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty && value.utf8.count <= 1024 && parts.count <= 16
            && !value.contains("\\") && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
    }
    private static func ownedPath(_ value: String) -> Bool {
        validRelative(value) && locations.contains { value.hasPrefix(targetPrefix + $0.1 + "/") }
    }
    private static func readManifest(_ url: URL, gate: RootGate, ignored: inout Int) throws -> [Entry]? {
        guard try state(url) != nil else { return nil }
        let value = try JSONDecoder().decode(Manifest.self, from: boundedRead(url, maximum: maximumManifestBytes))
        guard value.schema == 1, value.files.count <= maximumFiles else { throw Failure.refused }
        var seen = Set<String>(), entries = [Entry]()
        for entry in value.files {
            guard ownedPath(entry.path) else { ignored += 1; continue }
            guard entry.sha256.utf8.count == 64, entry.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                seen.insert(entry.path.lowercased()).inserted else { throw Failure.refused }
            _ = try gate.url(entry.path)
            entries.append(entry)
        }
        return entries
    }
    private static func writeNew(_ data: Data, to url: URL, mode: mode_t) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw Failure.refused }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.close() }
        catch { try? handle.close(); try? FileManager.default.removeItem(at: url); throw error }
    }
    private static func state(_ url: URL) throws -> stat? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { if errno == ENOENT { return nil }; throw Failure.refused }
        return value
    }
    private static func isDirectory(_ value: stat) -> Bool { UInt32(value.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    private static func isRegular(_ value: stat) -> Bool { UInt32(value.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) }
    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func digest(_ url: URL, maximum: Int = maximumFileBytes) throws -> String { sha(try boundedRead(url, maximum: maximum)) }
    private static func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        guard let initial = try state(url), isRegular(initial), initial.st_nlink == 1,
            initial.st_size >= 0, initial.st_size <= maximum else { throw Failure.refused }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.refused }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(16 * 1024, maximum - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= maximum - data.count else { throw Failure.refused }; data.append(chunk)
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0, let named = try state(url), isRegular(final), final.st_nlink == 1,
            initial.st_dev == final.st_dev, initial.st_ino == final.st_ino, initial.st_size == final.st_size,
            initial.st_mode == final.st_mode,
            initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec, initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
            named.st_dev == final.st_dev, named.st_ino == final.st_ino, data.count == final.st_size else { throw Failure.refused }
        return data
    }
    private struct RootGate {
        let root: URL
        let device: dev_t, inode: ino_t
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        init(_ root: URL) throws {
            guard root.isFileURL, root.host == nil || root.host == "", root.user == nil, root.password == nil,
                root.query == nil, root.fragment == nil, root.path != "/", root.path.hasPrefix("/"),
                root.path.utf8.count <= 1024, root.standardizedFileURL.path == root.path,
                let item = try state(root), isDirectory(item), item.st_uid == geteuid(), item.st_mode & 0o077 == 0 else { throw Failure.refused }
            let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
            guard let normal = try state(home), item.st_dev != normal.st_dev || item.st_ino != normal.st_ino else { throw Failure.refused }
            self.root = root; device = item.st_dev; inode = item.st_ino
            try check()
        }
        func check() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                let item = try state(root), isDirectory(item), item.st_dev == device, item.st_ino == inode,
                item.st_uid == geteuid(), item.st_mode & 0o077 == 0 else { throw Failure.refused }
            var parent = root
            while parent.path != "/" {
                guard let value = try state(parent), isDirectory(value) else { throw Failure.refused }
                parent.deleteLastPathComponent()
            }
        }
        func url(_ relative: String) throws -> URL {
            try check(); guard validRelative(relative) else { throw Failure.refused }
            var result = root
            let components = relative.split(separator: "/")
            for (index, part) in components.enumerated() {
                result.appendPathComponent(String(part))
                if let value = try state(result) {
                    guard index == components.count - 1 ? (isDirectory(value) || isRegular(value)) : isDirectory(value) else { throw Failure.refused }
                }
            }
            return result
        }
    }
    private static func pruneEmptyParents(of file: URL, root: URL) {
        var directory = file.deletingLastPathComponent()
        while directory.path.hasPrefix(root.appendingPathComponent("Library").path + "/") {
            guard rmdir(directory.path) == 0 else { return }
            directory.deleteLastPathComponent()
        }
    }
}
