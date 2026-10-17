import XCTest
@testable import RemSoundCore

final class ProfileStoreTests: XCTestCase {
    func testSavedNamesAndUnresolvedNamesRoundTripWithoutSchemaChanges() throws {
        let directory = try IsolatedTestDirectory.root()
            .appendingPathComponent("remsound-profile-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        var saved = profile(title: "Saved peer names")
        saved.selectedPeerAddresses = ["missing.local", "studio.local", "192.0.2.1"]
        try store.save(saved)
        XCTAssertEqual(try store.load(id: saved.id).selectedPeerAddresses, saved.selectedPeerAddresses)
    }

    func testRecentProfilesKeepFiveDistinctMostRecentIDs() {
        let ids = (0..<6).map { _ in UUID() }
        var recent = [UUID]()
        for id in ids { recent = RecentProfileHistory.opening(id, in: recent) }
        XCTAssertEqual(recent, Array(ids.reversed().prefix(5)))
        recent = RecentProfileHistory.opening(ids[2], in: recent)
        XCTAssertEqual(recent, [ids[2], ids[5], ids[4], ids[3], ids[1]])
    }

    private func profile(title: String, id: UUID = UUID()) -> ConnectionProfile {
        ConnectionProfile(
            id: id, title: title, displayName: "Mac", manualPeerAddress: "192.0.2.1",
            selectedPeerAddresses: ["192.0.2.1"], sendInput: false, receiveAudio: true,
            allowPlugins: true, reconnectOnOpen: true,
            inputDeviceUID: "test-input-uid", outputDeviceUID: "test-output-uid",
            systemCaptureDeviceUID: "test-capture-uid")
    }

    /// Windows' PROFILE SAFETY: one profile that cannot be read never takes the others with it, and is never saved over.
    func testADamagedProfileIsLeftAloneAndTheOthersStillOpenAndSave() throws {
        let directory = try IsolatedTestDirectory.root()
            .appendingPathComponent("remsound-profile-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        try store.save(profile(title: "Evening"))
        let damaged = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{ \"id\": \"not a profile".utf8).write(to: damaged)
        XCTAssertEqual(try store.list().map(\.title), ["Evening"], "the readable one still listed")
        XCTAssertEqual(store.unreadable().map(\.lastPathComponent), [damaged.lastPathComponent], "and the damaged one named")
        try store.save(profile(title: "Night"))
        XCTAssertEqual(try store.list().map(\.title), ["Evening", "Night"], "saving still works")
        XCTAssertEqual(try Data(contentsOf: damaged), Data("{ \"id\": \"not a profile".utf8), "the damaged file untouched")
    }

    func testRoundTripRenameAndDeleteWithoutPasswordOnDisk() throws {
        let directory = try IsolatedTestDirectory.root()
            .appendingPathComponent("remsound-profile-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        var morning = profile(title: "Morning")
        morning.peerAliases = ["192.0.2.1": "Studio PC"]
        try store.save(morning)
        XCTAssertEqual(try store.list(), [morning])
        XCTAssertEqual(try store.load(id: morning.id), morning)
        let folderPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let filePath = directory.appendingPathComponent("\(morning.id.uuidString).json").path
        let filePermissions = try FileManager.default.attributesOfItem(atPath: filePath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(folderPermissions?.intValue, 0o700)
        XCTAssertEqual(filePermissions?.intValue, 0o600)
        let raw = try String(contentsOf: directory.appendingPathComponent("\(morning.id.uuidString).json"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("password"))
        morning.title = "Evening"
        try store.save(morning)
        XCTAssertEqual(try store.list().map(\.title), ["Evening"])
        try store.delete(id: morning.id)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testDuplicateNamesCannotOverwriteAnotherProfile() throws {
        let directory = try IsolatedTestDirectory.root()
            .appendingPathComponent("remsound-profile-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let first = profile(title: "Evening")
        try store.save(first)
        XCTAssertThrowsError(try store.save(profile(title: " evening "))) { error in
            XCTAssertEqual(error as? ProfileStoreError, .duplicateTitle)
        }
        XCTAssertEqual(try store.load(id: first.id), first)
    }

    func testLegacyProfileDefaultsToMacOutputMonitoring() throws {
        let legacy = profile(title: "Existing")
        var values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        values.removeValue(forKey: "monitorInApp")
        values.removeValue(forKey: "inputDeviceUID")
        values.removeValue(forKey: "inputDeviceUIDs")
        values.removeValue(forKey: "inputChannelPairs")
        values.removeValue(forKey: "outputDeviceUID")
        values.removeValue(forKey: "outputDeviceUIDs")
        values.removeValue(forKey: "outputChannelPairs")
        values.removeValue(forKey: "systemCaptureDeviceUID")
        values.removeValue(forKey: "systemCaptureDeviceUIDs")
        values.removeValue(forKey: "systemCaptureChannelPairs")
        values.removeValue(forKey: "receiveJitterMs")
        values.removeValue(forKey: "receiveAutoTune")
        values.removeValue(forKey: "receiveAutoTuneInterval")
        values.removeValue(forKey: "sendCodec")
        values.removeValue(forKey: "recordingSource")
        values.removeValue(forKey: "recordingFormat")
        values.removeValue(forKey: "recordingChannels")
        values.removeValue(forKey: "recordingsDirectory")
        values.removeValue(forKey: "peerMixes")
        values.removeValue(forKey: "peerAliases")
        let data = try JSONSerialization.data(withJSONObject: values)
        let restored = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        XCTAssertTrue(restored.monitorInApp)
        XCTAssertEqual(restored.inputDeviceUID, "")
        XCTAssertEqual(restored.inputDeviceUIDs, [""])
        XCTAssertEqual(restored.inputChannelPairs, [:])
        XCTAssertEqual(restored.outputDeviceUID, "")
        XCTAssertEqual(restored.outputDeviceUIDs, [""])
        XCTAssertEqual(restored.outputChannelPairs, [:])
        XCTAssertEqual(restored.systemCaptureDeviceUID, "")
        XCTAssertNil(restored.systemCaptureDeviceUIDs)
        XCTAssertEqual(restored.systemCaptureChannelPairs, [:])
        XCTAssertEqual(restored.sendCodec, .pcm)
        XCTAssertEqual(restored.receiveJitterMs, ReceiveBuffer.legacyDefaultMs)
        XCTAssertFalse(restored.receiveAutoTune)
        XCTAssertEqual(restored.receiveAutoTuneInterval,
            ReceiveBuffer.defaultAutoTuneInterval)
        XCTAssertEqual(restored.recordingSource, .both)
        XCTAssertEqual(restored.recordingFormat, .wav24)
        XCTAssertEqual(restored.recordingChannels, .stereo)
        XCTAssertEqual(restored.recordingsDirectory, "")
        XCTAssertTrue(restored.peerMixes.isEmpty)
        XCTAssertTrue(restored.peerAliases.isEmpty)
    }

    func testMonoRecordingChoiceSurvivesProfileRoundTrip() throws {
        var selected = profile(title: "Mono session")
        selected.recordingChannels = .mono
        let restored = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONEncoder().encode(selected))
        XCTAssertEqual(restored.recordingChannels, .mono)
    }

    func testReceiveJitterTargetSurvivesProfileRoundTrip() throws {
        var selected = profile(title: "Network session")
        selected.receiveJitterMs = 80
        selected.receiveAutoTune = true
        selected.receiveAutoTuneInterval = 15
        let restored = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONEncoder().encode(selected))
        XCTAssertEqual(restored.receiveJitterMs, 80)
        XCTAssertTrue(restored.receiveAutoTune)
        XCTAssertEqual(restored.receiveAutoTuneInterval, 15)
    }

    func testLegacySingleCaptureOutputMigratesAndMultipleOutputsRoundTrip() throws {
        var legacy = profile(title: "Existing")
        var values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        values.removeValue(forKey: "systemCaptureDeviceUIDs")
        values["systemCaptureDeviceUID"] = "test-capture-uid"
        let legacyData = try JSONSerialization.data(withJSONObject: values)
        let migrated = try JSONDecoder().decode(ConnectionProfile.self, from: legacyData)
        XCTAssertEqual(migrated.systemCaptureDeviceUIDs, ["test-capture-uid"])

        legacy.systemCaptureDeviceUIDs = ["first-output", "second-output"]
        legacy.systemCaptureChannelPairs = ["first-output": [1, 2]]
        let restored = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONEncoder().encode(legacy))
        XCTAssertEqual(restored.systemCaptureDeviceUIDs,
            ["first-output", "second-output"])
        XCTAssertEqual(restored.systemCaptureChannelPairs, ["first-output": [1, 2]])

        legacy.systemCaptureDeviceUIDs = []
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONEncoder().encode(legacy)).systemCaptureDeviceUIDs, [])
        legacy.systemCaptureDeviceUIDs = nil
        XCTAssertNil(try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONEncoder().encode(legacy)).systemCaptureDeviceUIDs)
    }

    func testLegacySingleInputMigratesAndMultipleInputsRoundTrip() throws {
        var profile = profile(title: "Inputs")
        var values = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(profile)) as! [String: Any]
        values.removeValue(forKey: "inputDeviceUIDs")
        let migrated = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONSerialization.data(withJSONObject: values))
        XCTAssertEqual(migrated.inputDeviceUIDs, ["test-input-uid"])

        profile.inputDeviceUIDs = ["first-input", "second-input"]
        profile.inputChannelPairs = ["first-input": [0, 2]]
        profile.outputChannelPairs = ["test-output-uid": [1, 2]]
        let restored = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.inputDeviceUIDs, ["first-input", "second-input"])
        XCTAssertEqual(restored.inputChannelPairs, ["first-input": [0, 2]])
        XCTAssertEqual(restored.outputChannelPairs, ["test-output-uid": [1, 2]])
        profile.inputDeviceUIDs = []
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONEncoder().encode(profile)).inputDeviceUIDs, [])
    }

    func testLegacySinglePlaybackOutputMigratesAndMultipleOutputsRoundTrip() throws {
        var profile = profile(title: "Playback")
        var values = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(profile)) as! [String: Any]
        values.removeValue(forKey: "outputDeviceUIDs")
        let migrated = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONSerialization.data(withJSONObject: values))
        XCTAssertEqual(migrated.outputDeviceUIDs, ["test-output-uid"])

        profile.outputDeviceUIDs = ["first-output", "second-output"]
        profile.outputChannelPairs = ["first-output": [1], "second-output": [0, 2]]
        let restored = try JSONDecoder().decode(ConnectionProfile.self,
            from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.outputDeviceUIDs, ["first-output", "second-output"])
        XCTAssertEqual(restored.outputChannelPairs,
            ["first-output": [1], "second-output": [0, 2]])
    }

    func testSaveHardensExistingProfilePermissions() throws {
        let directory = try IsolatedTestDirectory.root()
            .appendingPathComponent("remsound-profile-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let store = ProfileStore(directory: directory)
        let saved = profile(title: "Existing")
        try store.save(saved)
        let path = directory.appendingPathComponent("\(saved.id.uuidString).json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try store.save(saved)
        let folderMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(folderMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
    }
}
