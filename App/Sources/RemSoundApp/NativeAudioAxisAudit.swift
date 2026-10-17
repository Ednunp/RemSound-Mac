import Foundation
import CryptoKit
import AppKit
import RemSoundCore
import RemSoundRuntime

@MainActor
enum NativeAudioAxisAudit {
    struct Review {
        let inside: Int, outside: Int
        let reason: String
        var exempt = false
        var coveredBy: String? = nil
    }
    struct Method {
        let id: String, body: String
        let inside: Int, outside: Int
        let covers: Bool, speakers: Bool
    }
    static let axis = #"\b(?:PlaybackFanout|OutputClock|DeviceAudio|OutputChannelMap)\b|\b(?:writePlayback|outputDeviceUIDs?|outputUIDs|monitorInApp|outputClocks|checkNativeOutputFanout)\b|\btestPlayback\s*\(|\brun\s*\(card:"#
    static let assertion = #"(?<!func )\b(?:XCTAssert\w*|XCTFail|XCTUnwrap|require)\s*\("#
    static let configurationLoop = #"\bfor\s+\w+\s+in\s+(?:ProductTestPack\.)?nativeOutputCounts\s*\{"#
    static func closingBrace(_ code: NSString, open: Int) -> Int? {
        var depth = 0
        for position in open..<code.length {
            if code.character(at: position) == 123 { depth += 1 }
            if code.character(at: position) == 125 { depth -= 1; if depth == 0 { return position } }
        }
        return nil
    }
    static func methods(_ sources: [String: String]) -> [Method] {
        var found = [Method]()
        guard let declaration = try? NSRegularExpression(pattern: #"\bfunc\s+((?:test|check)\w+)\s*\("#),
            let touching = try? NSRegularExpression(pattern: axis),
            let checks = try? NSRegularExpression(pattern: assertion),
            let loops = try? NSRegularExpression(pattern: configurationLoop) else { return [] }
        for (file, text) in sources.sorted(by: { $0.key < $1.key }) {
            guard (file.contains("/Tests/") || file.contains("/Sources/RemSoundCore/Product")),
                file.hasSuffix(".swift"), file != "App/Tests/RemSoundAppTests/NativeAudioAxisAuditTests.swift" else { continue }
            let code = NativeDialogAudit.codeOnly(text) as NSString
            for match in declaration.matches(in: code as String, range: NSRange(location: 0, length: code.length)) {
                let name = code.substring(with: match.range(at: 1))
                let tail = NSRange(location: NSMaxRange(match.range), length: code.length - NSMaxRange(match.range))
                let open = code.range(of: "{", range: tail).location
                guard open != NSNotFound, let close = closingBrace(code, open: open) else { continue }
                let body = code.substring(with: NSRange(location: open, length: close - open + 1))
                let range = NSRange(location: 0, length: (body as NSString).length)
                guard touching.firstMatch(in: body, range: range) != nil else { continue }
                let assertionRanges = checks.matches(in: body, range: range).map(\.range)
                let loopRanges = loops.matches(in: body, range: range).compactMap { match -> NSRange? in
                    let start = NSMaxRange(match.range) - 1
                    guard let end = closingBrace(body as NSString, open: start) else { return nil }
                    return NSRange(location: start, length: end - start + 1)
                }
                let inside = assertionRanges.filter { check in loopRanges.contains { NSLocationInRange(check.location, $0) } }.count
                found.append(.init(id: file + "." + name, body: body, inside: inside, outside: assertionRanges.count - inside,
                    covers: !loopRanges.isEmpty, speakers: body.contains(".read(") || body.contains(".take(") || body.contains(".heard") || body.contains(".testPlayback(")))
            }
        }
        return found
    }
    static func inspect(_ sources: [String: String], reviews: [String: Review]? = nil, names: [String]) -> (assertions: Int, failures: [String]) {
        let reviews = reviews ?? reviewed, found = methods(sources)
        var count = 0, failures = [String]()
        func require(_ condition: Bool, _ code: String) { count += 1; if !condition { failures.append("audio-axis.native." + code) } }
        func id(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }
        require(!found.isEmpty, "empty-audio-method-census")
        require([axis, assertion, configurationLoop].allSatisfy { (try? NSRegularExpression(pattern: $0)) != nil }, "invalid-audio-pattern")
        require(names.count > 100 && Set(names).count == names.count, "empty-or-duplicate-step-catalog")
        require(Set(found.map(\.id)).count == found.count, "duplicate-method-identity")
        let ids = Set(found.map(\.id))
        for key in reviews.keys.sorted() { require(ids.contains(key), "stale-review-" + id(key)) }
        for method in found {
            guard let review = reviews[method.id] else { require(false, "unreviewed-" + id(method.id)); continue }
            require(review.reason.count >= 40, "bare-reason-" + id(method.id))
            require(method.inside == review.inside && method.outside == review.outside, "assertion-drift-" + id(method.id))
            if method.covers { require(method.inside > 0, "decorative-loop-" + id(method.id)) }
            if method.id == "App/Sources/RemSoundCore/ProductAudioConfigurations.swift.checkNativeOutputFanout" {
                let code = method.body as NSString
                let modes = try? NSRegularExpression(pattern: #"\bfor\s+\w+\s+in\s+nativeCardModes\s*\{"#)
                let match = modes?.firstMatch(in: method.body, range: NSRange(location: 0, length: code.length))
                var modeAssertions = 0
                if let match, let end = closingBrace(code, open: NSMaxRange(match.range) - 1),
                    let checks = try? NSRegularExpression(pattern: assertion) {
                    modeAssertions = checks.numberOfMatches(in: method.body, range: NSRange(location: NSMaxRange(match.range), length: end - NSMaxRange(match.range)))
                }
                require(method.inside > 0 && modeAssertions == method.inside, "missing-card-mode-assertions")
            }
            if review.exempt {
                require(!method.covers, "stale-exemption-" + id(method.id))
                if let target = review.coveredBy {
                    let name = target.split(separator: ".").last.map(String.init) ?? ""
                    require(found.contains { $0.id == target && $0.covers && $0.inside > 0 } && method.body.contains(name + "("), "missing-covering-driver-" + id(method.id))
                }
                if method.speakers { require(review.reason.contains("cannot be anything else") || review.coveredBy != nil, "speaker-exemption-" + id(method.id)) }
            } else if !method.covers { failures.append("audio-axis.native.unverified-" + id(method.id)) }
        }
        return (count, failures)
    }
    static let reviewed: [String: Review] = [
        "App/Tests/RemSoundCoreTests/RecordingBypassTests.swift.checkRecording": .init(inside: 0, outside: 11, reason: "The actual stopped Session playback read has related retained production cases; complete native output-configuration and exact driver evidence still needs joining, not a claim of a missing feature."),
        "App/Tests/RemSoundCoreTests/SelfMonitoringSessionTests.swift.testRealRelayReturnsTwoDAWStreamsWithoutPeersAndMuteStopsPlayback": .init(inside: 0, outside: 15, reason: "The actual stopped Session playback read has related retained production cases; complete native output-configuration and exact driver evidence still needs joining, not a claim of a missing feature."),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputClockTests.swift.testEveryCardAndMixBlockIsHeldAtItsCushionAndNeverRunsDry": .init(inside: 0, outside: 5, reason: "One output clock is fed controlled card pulls and mix blocks as arithmetic; it cannot be anything else. No device selection or shared fanout is involved, and repeating this mechanism for output counts would feed the same function the same values.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputClockTests.swift.testLeftAloneTheSameQueueWalksAway": .init(inside: 0, outside: 3, reason: "One output clock is fed controlled card pulls and mix blocks as arithmetic; it cannot be anything else. No device selection or shared fanout is involved, and repeating this mechanism for output counts would feed the same function the same values.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputClockTests.swift.testACardThatStartsLateIsBoundedByCapacityAndConvergesWithoutACut": .init(inside: 0, outside: 5, reason: "One output clock is fed controlled card pulls and mix blocks as arithmetic; it cannot be anything else. No device selection or shared fanout is involved, and repeating this mechanism for output counts would feed the same function the same values.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputClockTests.swift.testActualPullSizesTheCushionDespiteAnIncorrectAdvertisedBuffer": .init(inside: 0, outside: 3, reason: "One output clock is fed controlled card pulls and mix blocks as arithmetic; it cannot be anything else. No device selection or shared fanout is involved, and repeating this mechanism for output counts would feed the same function the same values.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputClockTests.swift.testAMixThatComesLateDoesNotHaveItsCushionRaised": .init(inside: 0, outside: 5, reason: "One output clock is fed controlled card pulls and mix blocks as arithmetic; it cannot be anything else. No device selection or shared fanout is involved, and repeating this mechanism for output counts would feed the same function the same values.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputClockTests.swift.testWhatTheCardPlaysHasNoClickInIt": .init(inside: 0, outside: 3, reason: "One output clock is fed controlled card pulls and mix blocks as arithmetic; it cannot be anything else. No device selection or shared fanout is involved, and repeating this mechanism for output counts would feed the same function the same values.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputClockTests.swift.testAQueueEmptiedAndStartedAgainIsGivenItsCushionAgain": .init(inside: 0, outside: 4, reason: "One output clock is fed controlled card pulls and mix blocks as arithmetic; it cannot be anything else. No device selection or shared fanout is involved, and repeating this mechanism for output counts would feed the same function the same values.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputCushionTests.swift.testAQueueBelowCapacityIsNeverCutTowardItsTarget": .init(inside: 0, outside: 2, reason: "A single queue cushion is driven by measured pull counters as arithmetic; it cannot be anything else. Output selection does not enter this primitive, and fanout is checked by checkNativeOutputFanout.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputCushionTests.swift.testUnmeasuredCardStartsAtTwelveMilliseconds": .init(inside: 0, outside: 1, reason: "A single queue cushion is driven by measured pull counters as arithmetic; it cannot be anything else. Output selection does not enter this primitive, and fanout is checked by checkNativeOutputFanout.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputCushionTests.swift.testEmptyReadsNeverRaiseTheTarget": .init(inside: 0, outside: 2, reason: "A single queue cushion is driven by measured pull counters as arithmetic; it cannot be anything else. Output selection does not enter this primitive, and fanout is checked by checkNativeOutputFanout.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputCushionTests.swift.testAdvertisedBufferChangesDoNotInventMeasuredPulls": .init(inside: 0, outside: 1, reason: "A single queue cushion is driven by measured pull counters as arithmetic; it cannot be anything else. Output selection does not enter this primitive, and fanout is checked by checkNativeOutputFanout.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputCushionTests.swift.testProducerStallDoesNotChangeTheTarget": .init(inside: 0, outside: 2, reason: "A single queue cushion is driven by measured pull counters as arithmetic; it cannot be anything else. Output selection does not enter this primitive, and fanout is checked by checkNativeOutputFanout.", exempt: true),
        "App/Packages/RemSoundJam/Tests/RemSoundJamTests/OutputCushionTests.swift.testClockUsesActualRequestedFramesIncludingShortReads": .init(inside: 0, outside: 2, reason: "A single queue cushion is driven by measured pull counters as arithmetic; it cannot be anything else. Output selection does not enter this primitive, and fanout is checked by checkNativeOutputFanout.", exempt: true),
        "App/Sources/RemSoundCore/ProductAudioConfigurations.swift.checkNativeOutputFanout": .init(inside: 9, outside: 3, reason: "The actual native fanout loop reads known stereo from every fallback, single-card and repeated multi-card output with assertions inside the loop."),
        "App/Sources/RemSoundCore/ProductAudioConfigurations.swift.checkAudioConfigurations": .init(inside: 0, outside: 0, reason: "This scalar caller invokes checkNativeOutputFanout, whose actual canonical output-count loop reads every output and owns the configuration assertions.", exempt: true, coveredBy: "App/Sources/RemSoundCore/ProductAudioConfigurations.swift.checkNativeOutputFanout"),
        "App/Tests/RemSoundCoreTests/AudioConfigurationCoverageProductTests.swift.testActualNativeSoftwareOutputBranchesPreserveKnownStereoAndRetire": .init(inside: 0, outside: 2, reason: "This scalar caller invokes checkNativeOutputFanout, whose actual canonical output-count loop reads every output and owns the configuration assertions.", exempt: true, coveredBy: "App/Sources/RemSoundCore/ProductAudioConfigurations.swift.checkNativeOutputFanout"),
        "App/Tests/RemSoundCoreTests/AudioDeviceCatalogTests.swift.testSelectedInputAndOutputStartOnRealHardware": .init(inside: 0, outside: 1, reason: "Existing capture, monitoring or live output-selection behaviour still needs an exact native configuration and retained driver join; source presence is not hardware or routing acceptance."),
        "App/Tests/RemSoundCoreTests/AudioPathMeasurementTests.swift.testRealCaptureReturnSeparatesNetworkReceiveAndOutputQueues": .init(inside: 0, outside: 11, reason: "Existing capture, monitoring or live output-selection behaviour still needs an exact native configuration and retained driver join; source presence is not hardware or routing acceptance."),
        "App/Tests/RemSoundCoreTests/AudioRingTests.swift.testPlaybackFanoutGivesEachOutputTheSameFrames": .init(inside: 0, outside: 4, reason: "This test is the repeated multi-output fanout itself and cannot be anything else; reading two independent rings proves duplication rather than splitting. Fallback, single and repeated multi-card branches also execute in checkNativeOutputFanout.", exempt: true),
        "App/Tests/RemSoundCoreTests/CaptureInputClockTests.swift.testHardwareObservationRequiresCoherentNormalizedPhysicalInput": .init(inside: 0, outside: 2, reason: "This checks coherent normalized capture metadata from a supplied input ring, before playback. Which outputs are selected cannot change the input origin or frame observation.", exempt: true),
        "App/Tests/RemSoundCoreTests/OutputChannelMapTests.swift.testStereoCanPlayOnSelectedPairsOfSixChannelDevice": .init(inside: 0, outside: 2, reason: "The channel map is pure array arithmetic for supplied channel counts and pair indexes; selected output count never enters this function and no device is opened.", exempt: true),
        "App/Tests/RemSoundCoreTests/OutputChannelMapTests.swift.testRejectsMissingAndOutOfRangePairs": .init(inside: 0, outside: 3, reason: "The channel map is pure array arithmetic for supplied channel counts and pair indexes; selected output count never enters this function and no device is opened.", exempt: true),
        "App/Tests/RemSoundCoreTests/OutputPullMetricsTests.swift.testEachPhysicalOutputRingHasOnlyOneHundredMillisecondsCapacity": .init(inside: 0, outside: 4, reason: "A single ring capacity or output clock pull counter is the mechanism under test and cannot be anything else; output selection cannot alter that primitive. Actual multi-output duplication is checkNativeOutputFanout.", exempt: true),
        "App/Tests/RemSoundCoreTests/OutputPullMetricsTests.swift.testProductionRingSuppliesTheClockWithActualPulls": .init(inside: 0, outside: 2, reason: "A single ring capacity or output clock pull counter is the mechanism under test and cannot be anything else; output selection cannot alter that primitive. Actual multi-output duplication is checkNativeOutputFanout.", exempt: true),
        "App/Tests/RemSoundCoreTests/ProfileStoreTests.swift.testLegacyProfileDefaultsToMacOutputMonitoring": .init(inside: 0, outside: 20, reason: "Output UID lists and monitoring are profile data being saved and loaded. This does not render or select a physical device; varying playback would repeat the same persistence function.", exempt: true),
        "App/Tests/RemSoundCoreTests/ProfileStoreTests.swift.testLegacySinglePlaybackOutputMigratesAndMultipleOutputsRoundTrip": .init(inside: 0, outside: 3, reason: "Output UID lists and monitoring are profile data being saved and loaded. This does not render or select a physical device; varying playback would repeat the same persistence function.", exempt: true),
        "App/Tests/RemSoundCoreTests/ReceiveArtifactTests.swift.testSessionAppliesArtifactToExistingAndNewStreamsAndPublishesIt": .init(inside: 0, outside: 6, reason: "This stopped-output isolated receiver changes per-stream decoder policy and reports the choice. Monitoring is explicitly off; the decode policy is applied before any output or fanout.", exempt: true),
        "App/Tests/RemSoundCoreTests/ReceiveSmoothnessTests.swift.testSessionAppliesChoiceToExistingAndNewStreamsAndPublishesIt": .init(inside: 0, outside: 6, reason: "This stopped-output isolated receiver changes per-stream decoder policy and reports the choice. Monitoring is explicitly off; the decode policy is applied before any output or fanout.", exempt: true),
        "App/Tests/RemSoundCoreTests/SessionTests.swift.testAppMonitoringCanBeOffWhileDAWReceivesPeerAudio": .init(inside: 0, outside: 2, reason: "Existing capture, monitoring or live output-selection behaviour still needs an exact native configuration and retained driver join; source presence is not hardware or routing acceptance."),
        "App/Tests/RemSoundCoreTests/SessionTests.swift.testLiveAudioOptionsPreserveSessionAndPeerSelection": .init(inside: 0, outside: 11, reason: "Existing capture, monitoring or live output-selection behaviour still needs an exact native configuration and retained driver join; source presence is not hardware or routing acceptance."),
    ]
}

enum BootstrapAudioAxisAudit {
    static let permission = "REMSOUND_TEST_NATIVE_AUDIO_AXIS"
    static func run(for options: LaunchOptions) -> (assertions: Int, failures: [String])? {
        let environment = ProcessInfo.processInfo.environment
        guard BootstrapProfileLogging.accepts(root: options.configurationDirectory, environment: environment, permission: permission),
            Thread.isMainThread, AppRuntime.configuration == nil else { return nil }
        do {
            let source = try BootstrapDialogAudit.sources(environment: environment, includeNativeSources: true)
            return MainActor.assumeIsolated {
                guard NSApp == nil else { return (1, ["audio-axis.native.native-application-already-created"]) }
                return NativeAudioAxisAudit.inspect(source, names: ProductTestPack.names)
            }
        } catch { return (1, ["audio-axis.native.isolated-source-refused"]) }
    }
}
