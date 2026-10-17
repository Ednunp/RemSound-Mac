import Foundation

public enum UpdateCatalog {
    public static let repository = "OnjLouis/RemSound-Mac"
    public static let releasesURL = URL(
        string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!

    public struct Candidate: Equatable {
        public let version: String
        public let assetName: String
        public let downloadURL: URL
        public let releaseURL: URL
        /// The release's notes, as written on GitHub (shown, shortened, in the question before installing).
        public var notes: String = ""
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        let body: String?
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }

    private struct Version: Comparable {
        let parts: [Int]

        init?(_ raw: String) {
            let fields = raw.split(separator: ".", omittingEmptySubsequences: false)
            guard fields.count == 3,
                fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                fields.allSatisfy({ Int($0) != nil }) else { return nil }
            parts = fields.compactMap { Int($0) }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.parts.lexicographicallyPrecedes(rhs.parts)
        }
    }

    public static func newest(in data: Data, newerThan current: String) throws -> Candidate? {
        guard let currentVersion = Version(current) else { return nil }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        return releases.compactMap { release -> (Version, Candidate)? in
            guard !release.draft, !release.prerelease,
                release.tag_name.hasPrefix("v"),
                let version = Version(String(release.tag_name.dropFirst())),
                version > currentVersion else { return nil }
            let rawVersion = String(release.tag_name.dropFirst())
            let expected = "RemSound-Mac-v\(rawVersion).zip"
            guard let asset = release.assets.first(where: { $0.name == expected }),
                asset.browser_download_url.scheme == "https",
                asset.browser_download_url.host == "github.com",
                asset.browser_download_url.path.hasPrefix(
                    "/\(repository)/releases/download/\(release.tag_name)/") else { return nil }
            return (version, Candidate(version: rawVersion, assetName: expected,
                downloadURL: asset.browser_download_url, releaseURL: release.html_url, notes: release.body ?? ""))
        }.max { $0.0 < $1.0 }?.1
    }
}
