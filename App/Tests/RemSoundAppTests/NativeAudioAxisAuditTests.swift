import XCTest
import CryptoKit
import RemSoundCore
@testable import RemSoundApp

@MainActor final class NativeAudioAxisAuditTests: XCTestCase {
    private let file = "App/Tests/RemSoundCoreTests/OutputTests.swift"
    private let reason = "The actual production fanout outputs are checked inside each native configuration."
    func testCurrentPrivateSnapshotIsFullyReviewed() throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try XCTUnwrap(environment["REMSOUND_TEST_ROOT"])
        let sources = try BootstrapDialogAudit.sources(environment: environment, includeNativeSources: true)
        let found = NativeAudioAxisAudit.methods(sources)
        let rows: [[String: Any]] = found.map { method in
            ["id": method.id, "inside": method.inside, "outside": method.outside, "covers": method.covers,
             "speakers": method.speakers, "bodySHA256": SHA256.hash(data: Data(method.body.utf8)).map { String(format: "%02x", $0) }.joined()]
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: root).appendingPathComponent("audio-axis-methods.json"))
        XCTAssertFalse(found.isEmpty)
        let result = NativeAudioAxisAudit.inspect(sources, names: ProductTestPack.names)
        XCTAssertTrue(result.failures.allSatisfy { $0.hasPrefix("audio-axis.native.unverified-") }, result.failures.joined(separator: ","))
    }
    func testLoopsCountActualAssertionsNotCommentsOrMessages() {
        let code = """
        func testOutput() {
            func require(_ value: Bool) {}
            let f = PlaybackFanout(primary: ring)
            // for count in nativeOutputCounts { XCTAssertTrue(true) }
            let message = "XCTAssertTrue(true)"
            for count in ProductTestPack.nativeOutputCounts { XCTAssertEqual(f.rings.count, count) }
            XCTAssertTrue(f.clocks.isEmpty)
        }
        """
        let method = NativeAudioAxisAudit.methods([file: code])
        XCTAssertEqual(method.count, 1); XCTAssertEqual(method[0].inside, 1); XCTAssertEqual(method[0].outside, 1)
        let review = [file + ".testOutput": NativeAudioAxisAudit.Review(inside: 1, outside: 1, reason: reason)]
        XCTAssertTrue(NativeAudioAxisAudit.inspect([file: code], reviews: review, names: ProductTestPack.names).failures.isEmpty)
        let changed = code.replacingOccurrences(of: "XCTAssertTrue(f.clocks.isEmpty)", with: "XCTAssertTrue(f.clocks.isEmpty); XCTAssertTrue(true)")
        XCTAssertTrue(NativeAudioAxisAudit.inspect([file: changed], reviews: review, names: ProductTestPack.names).failures.contains { $0.contains("assertion-drift-") })
    }
    func testDecorativeOmittedAndStaleCoverageCannotDisappear() {
        let key = file + ".testOutput", code = "func testOutput() { let f = PlaybackFanout(primary: ring); for count in nativeOutputCounts { consume(f) } }"
        let review = [key: NativeAudioAxisAudit.Review(inside: 0, outside: 0, reason: reason)]
        XCTAssertTrue(NativeAudioAxisAudit.inspect([file: code], reviews: review, names: ProductTestPack.names).failures.contains { $0.contains("decorative-loop-") })
        let missing = code.replacingOccurrences(of: "for count in nativeOutputCounts", with: "for count in [1]")
        XCTAssertTrue(NativeAudioAxisAudit.inspect([file: missing], reviews: review, names: ProductTestPack.names).failures.contains { $0.contains("unverified-") })
        XCTAssertTrue(NativeAudioAxisAudit.inspect([:], reviews: review, names: ProductTestPack.names).failures.contains { $0.contains("stale-review-") })
        XCTAssertTrue(NativeAudioAxisAudit.inspect([file: code], reviews: [:], names: ProductTestPack.names).failures.contains { $0.contains("unreviewed-") })
    }
    func testSpeakerReadCannotUseAnUnjustifiedSingleConfiguration() {
        let key = file + ".testOutput", code = "func testOutput() { let f = PlaybackFanout(primary: ring); XCTAssertEqual(f.primary.read(1), samples) }"
        let review = [key: NativeAudioAxisAudit.Review(inside: 0, outside: 1, reason: reason, exempt: true)]
        XCTAssertTrue(NativeAudioAxisAudit.inspect([file: code], reviews: review, names: ProductTestPack.names).failures.contains { $0.contains("speaker-exemption-") })
    }
    func testActualFanoutDriverCannotOmitItsClockModeLoop() {
        let source = "App/Sources/RemSoundCore/ProductAudioConfigurations.swift"
        let code = "func checkNativeOutputFanout() { let f = PlaybackFanout(primary: ring); for count in nativeOutputCounts { for cards in nativeCardModes { require(f.rings.count == count) } } }"
        let reviews = [source + ".checkNativeOutputFanout": NativeAudioAxisAudit.Review(inside: 1, outside: 0, reason: reason)]
        XCTAssertTrue(NativeAudioAxisAudit.inspect([source: code], reviews: reviews, names: ProductTestPack.names).failures.isEmpty)
        let omitted = code.replacingOccurrences(of: "in nativeCardModes", with: "in [false]")
        XCTAssertTrue(NativeAudioAxisAudit.inspect([source: omitted], reviews: reviews, names: ProductTestPack.names).failures.contains("audio-axis.native.missing-card-mode-assertions"))
    }
    func testOwnFixtureExclusionCannotHideAnotherPackagesTestFile() {
        let source = "App/Packages/Extra/Tests/ExtraTests/NativeAudioAxisAuditTests.swift"
        XCTAssertEqual(NativeAudioAxisAudit.methods([source: "func testOutput() { let f = PlaybackFanout(primary: ring) }"]).count, 1)
    }
    func testActualSessionPlaybackReadCannotEscapeTheAudioCensus() {
        let found = NativeAudioAxisAudit.methods([file: "func testOutput() { XCTAssertEqual(session.testPlayback(1), samples) }"])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.speakers, true)
    }
}
