import Darwin
import Foundation
import UpdateSupport

/// Checks raw release metadata and bounds native extraction before authenticating bundles.
public enum UpdateArchive {
    public static let maximumZIPBytes: Int64 = 250_000_000
    public static let maximumExpandedBytes: Int64 = 1_000_000_000
    static let maximumEntries = 10_000
    static let maximumPathBytes = 1_024
    private static let releaseCompressionMethods: Set<String> = ["stor", "defN", "defF", "defS", "defX"]
    public static let bundleNames = ["RemSound.app", "Plugins/AU/RemSound.component",
        "Plugins/VST3/RemSound.vst3", "Plugins/CLAP/RemSound.clap"]

    public static func payloadName(for version: String) throws -> String {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) && Int(part) != nil
        }) else { throw ArchiveError.invalidVersion }
        return "RemSound-Mac-v\(version)"
    }

    public static func validate(listing: String, details: String, version: String) throws {
        let prefix = try payloadName(for: version) + "/"
        let entries = listing.split(whereSeparator: \.isNewline).map(String.init)
        let roots = bundleNames.map { prefix + $0 + "/" }
        let parents = [prefix, prefix + "Plugins/", prefix + "Plugins/AU/",
            prefix + "Plugins/VST3/", prefix + "Plugins/CLAP/"]
        guard !entries.isEmpty, entries.count <= maximumEntries,
            entries.allSatisfy({ $0.utf8.count <= maximumPathBytes }), Set(entries).count == entries.count,
            roots.allSatisfy({ root in entries.contains(where: { $0.hasPrefix(root) }) }),
            entries.allSatisfy({ entry in
                !entry.contains("\\") && !entry.hasPrefix("/")
                    && !entry.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
                    && (roots.contains(where: { entry.hasPrefix($0) }) || parents.contains(entry))
            }) else { throw ArchiveError.invalidPaths }
        var count = 0, total: Int64 = 0
        for line in details.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let mode = fields.first, let kind = mode.first,
                "-dlbcps?".contains(kind) else { continue }
            guard kind == "-" || kind == "d", mode.count == 10, fields.count >= 7,
                releaseCompressionMethods.contains(String(fields[6])),
                let size = Int64(fields[3]), size >= 0 else { throw ArchiveError.invalidMetadata }
            // Subtraction avoids overflow when an untrusted central directory declares an enormous file.
            guard size <= maximumExpandedBytes - total else { throw ArchiveError.expansionLimit }
            total += size
            count += 1
        }
        guard count == entries.count else { throw ArchiveError.invalidMetadata }
    }

    struct ExtractionLimits {
        var maximumBytes: UInt64 = UInt64(maximumExpandedBytes)
        var maximumEntries: UInt32 = UInt32(UpdateArchive.maximumEntries)
    }

    /// Extracts a fixed update payload into a new private folder, with bounded raw
    /// metadata inspection and native write limits. Existing folders are never replaced.
    public static func extract(zip: URL, to destination: URL, version: String,
        timeout: TimeInterval = UpdateCommand.helperOperationTimeout) throws {
        try extract(zip: zip, to: destination, version: version, timeout: timeout, limits: ExtractionLimits())
    }

    static func extract(zip: URL, to destination: URL, version: String, timeout: TimeInterval,
        limits: ExtractionLimits) throws {
        let payload = try payloadName(for: version)
        guard timeout.isFinite, timeout > 0, timeout <= UpdateCommand.helperOperationTimeout else {
            throw ArchiveError.extraction("The update extraction deadline is invalid or expired.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var attributes = stat()
        guard lstat(zip.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
            attributes.st_size > 0, attributes.st_size <= maximumZIPBytes else {
            throw ArchiveError.extraction("The update ZIP is not a bounded regular file.")
        }
        func inspect(_ tool: String, _ arguments: [String]) throws -> String {
            try UpdateCommand.run(executable: URL(fileURLWithPath: tool), arguments: arguments,
                timeout: min(UpdateCommand.defaultTimeout, deadline - ProcessInfo.processInfo.systemUptime))
        }
        // ZIP readers may normalize original FIFO metadata to a regular file;
        // retain raw zipinfo checks in addition to the native write boundary.
        // The seekable reader indexes central entries before returning headers;
        // bounded raw inspection must finish before invoking that reader.
        let listing = try inspect("/usr/bin/unzip", ["-Z", "-1", zip.path])
        let details = try inspect("/usr/bin/zipinfo", ["-l", zip.path])
        try validate(listing: listing, details: details, version: version)
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw ArchiveError.extraction("The update extraction timed out.") }
        var result = RSUpdateResult()
        let status = rs_update_extract(zip.path, destination.path, payload, UInt64(maximumZIPBytes),
            limits.maximumBytes, limits.maximumEntries, remaining, &result)
        guard status != RS_UPDATE_OK else { return }
        let message = withUnsafeBytes(of: result.error) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        if result.created_root != 0 {
            // Do not remove a replacement path if another process moved our root.
            var root = stat()
            guard result.root_inode != 0, lstat(destination.path, &root) == 0,
                UInt64(root.st_ino) == result.root_inode, UInt64(bitPattern: Int64(root.st_dev)) == result.root_device,
                root.st_uid == geteuid(), root.st_mode & S_IFMT == S_IFDIR else {
                throw ArchiveError.extraction("\(message) The partial folder changed and was left untouched.")
            }
            do { try FileManager.default.removeItem(at: destination) }
            catch { throw ArchiveError.extraction("\(message) The partial update folder could not be removed.") }
        }
        throw ArchiveError.extraction(message.isEmpty ? "The update ZIP could not be extracted safely." : message)
    }

    private enum ArchiveError: LocalizedError {
        case invalidVersion, invalidPaths, invalidMetadata, expansionLimit
        case extraction(String)
        var errorDescription: String? {
            switch self {
            case .extraction(let message): message
            case .invalidVersion: "The update version is invalid."
            case .invalidPaths: "The update ZIP contains unexpected paths."
            case .invalidMetadata: "The update ZIP contains symbolic links or unsupported entry metadata."
            case .expansionLimit: "The update ZIP declares too much extracted data."
            }
        }
    }
}
