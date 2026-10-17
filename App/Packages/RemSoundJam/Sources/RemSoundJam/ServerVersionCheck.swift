import Foundation

/// Windows server-v2.17 comparison policy. Transport and the warning belong to the connection owner.
public enum ServerVersionCheck {
    public static let builtWith = "server-v2.17"
    private static let prefix = "server-v"
    public static let repository = "Ednunp/RemSound"
    public static let releaseListURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!
    private static let releasesURL = "https://github.com/\(repository)/releases"

    private static func numeric(_ tag: String?) -> [Int32]? {
        guard let tag, tag.lowercased().hasPrefix(prefix) else { return nil }
        let digits = tag.dropFirst(prefix.count).prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let parts = digits.split(separator: ".")
        guard (1...3).contains(parts.count) else { return nil }
        var version = [Int32](repeating: 0, count: 3)
        for (index, part) in parts.enumerated() {
            guard let value = Int32(part) else { return nil }
            version[index] = value
        }
        return version
    }

    public static func isPlainReleaseTag(_ tag: String?) -> Bool {
        guard let tag, numeric(tag) != nil else { return false }
        return tag.dropFirst(prefix.count).allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }

    public static func newest(_ released: String?) -> String {
        guard let released, let value = numeric(released), numeric(builtWith)!.lexicographicallyPrecedes(value) else { return builtWith }
        return released
    }

    public static func isOutOfDate(_ server: String?, latestReleased: String?) -> Bool {
        guard let version = numeric(server) else { return true }
        return version.lexicographicallyPrecedes(numeric(newest(latestReleased))!)
    }

    public static func latestCodeURL(_ released: String?) -> URL {
        URL(string: isPlainReleaseTag(released) ? releasesURL + "/tag/" + released! : releasesURL)!
    }

    /// Select the highest plain server release; missing flags, drafts and prereleases are not accepted.
    public static func newestRelease(in data: Data) -> String? {
        struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool }
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }
        var newest: String?
        for release in releases where !release.draft && !release.prerelease && isPlainReleaseTag(release.tag_name) {
            if newest == nil || numeric(newest)!.lexicographicallyPrecedes(numeric(release.tag_name)!) { newest = release.tag_name }
        }
        return newest
    }
}

/// Queue-owned injected release lookup. The fetch completion must return to the owner's queue.
/// Connections share an in-flight lookup; only successful plain tags are kept for one hour.
public final class ServerReleaseCache {
    public static let cacheLifetime: TimeInterval = 3600
    private let clock: () -> TimeInterval
    private let fetch: (@escaping (String?) -> Void) -> Void
    private var known: (tag: String, at: TimeInterval)?
    private var asking: UUID?
    private var waiting: [(String?) -> Void] = []

    public init(clock: @escaping () -> TimeInterval, fetch: @escaping (@escaping (String?) -> Void) -> Void) {
        self.clock = clock
        self.fetch = fetch
    }

    public func latest(_ completion: @escaping (String?) -> Void) {
        let now = clock()
        if let known, now.isFinite, now >= known.at, now - known.at < Self.cacheLifetime { completion(known.tag); return }
        waiting.append(completion)
        guard asking == nil else { return }
        let request = UUID()
        asking = request
        fetch { [weak self] tag in
            guard let self, self.asking == request else { return }
            self.asking = nil
            let value = ServerVersionCheck.isPlainReleaseTag(tag) ? tag : nil
            if let value { self.known = (value, self.clock()) } else { self.known = nil }
            let callbacks = self.waiting
            self.waiting.removeAll()
            callbacks.forEach { $0(value) }
        }
    }
}
