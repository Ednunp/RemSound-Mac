import Foundation
import XCTest
#if os(Windows)
import WinSDK
#endif

@testable import RemSoundJam

/// A REAL ENCODER, A REAL DECODER: the recorder fed by libopus (as the Mac's is, with the Windows recorder's settings),
/// its file read back by a separate reader in Python that checks every page and decodes every packet with libopus, then
/// lines the sound up against the tone that went in. Proves the pre-skip and the end are right to the sample, and that
/// the pages are ones a player accepts.
///
/// Windows only (it calls libopus through its variadic ctl by plain function pointers, which the Windows ABI allows and
/// Apple's arm64 does not): set REMSOUND_OPUS_DLL to an opus.dll (the Windows RemSound ships one) and REMSOUND_PYTHON.
final class OggOpusLiveTests: XCTestCase {
    func testARealEncodersFileDecodesToTheSoundGivenInTimeAndToTheSample() throws {
        #if os(Windows)
        let env = ProcessInfo.processInfo.environment
        guard let library = env["REMSOUND_OPUS_DLL"], let python = env["REMSOUND_PYTHON"] else {
            throw XCTSkip("set REMSOUND_OPUS_DLL (an opus.dll) and REMSOUND_PYTHON to run this")
        }
        let checker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("opus").appendingPathComponent("check-ogg-opus.py").path
        let opus = try LibOpus(library)
        for channels in [2, 1] {
            let encoder = try opus.fileEncoder(channels: channels, bitrate: 192_000)
            defer { opus.destroy(encoder) }
            let lookahead = opus.lookahead(encoder)
            XCTAssertGreaterThan(lookahead, 0)
            var (recorder, bytes) = OggOpusRecorder.start(channels: channels, preSkip: lookahead, serial: 42) { frame in
                opus.encode(encoder, frame, channels: channels)
            }
            // 1.05 s of a 997 Hz tone (the right side a quarter-cycle later), in the mix's 240-frame blocks.
            var n = 0
            for _ in 0..<210 {
                var block: [Float] = []
                for _ in 0..<240 {
                    let phase = 2 * Double.pi * 997 * Double(n) / 48000
                    block += [Float(0.3 * sin(phase)), Float(0.3 * sin(phase - Double.pi / 2))]
                    n += 1
                }
                bytes += recorder.append(stereo: block)
            }
            bytes += recorder.finish()
            XCTAssertEqual(recorder.failedFrames, 0)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("remsound-ogg-\(UUID().uuidString).opus")
            try Data(bytes).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [checker, file.path, library]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            let text = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let found = try XCTUnwrap(try JSONSerialization.jsonObject(with: text) as? [String: Any],
                                      String(decoding: text, as: UTF8.self))
            let what = "\(channels) channel(s): \(found)"
            for key in ["crc_ok", "sequences_ok", "one_serial", "bos_first", "eos_last", "eos_only_last", "no_continued", "tags_ok"] {
                XCTAssertEqual(found[key] as? Bool, true, "\(key), \(what)")
            }
            XCTAssertEqual(found["channels"] as? Int, channels, what)
            XCTAssertEqual(found["pre_skip"] as? Int, lookahead, what)
            XCTAssertEqual(found["frames"] as? Int, 50_400, "exactly the sound given, no more and no less: \(what)")
            XCTAssertEqual(found["lag"] as? Int, 0, "in time to the sample: the pre-skip is right: \(what)")
            XCTAssertGreaterThan(found["corr"] as? Double ?? 0, 0.99, what)
            XCTAssertEqual(found["level_db"] as? Double ?? -999, 0, accuracy: 0.5, what)
            XCTAssertEqual((found["problems"] as? [Any])?.count, 0, what)
        }
        #else
        throw XCTSkip("Windows only")
        #endif
    }
}

#if os(Windows)
/// libopus, loaded by name: just what the recorder test needs.
final class LibOpus {
    typealias Create = @convention(c) (Int32, Int32, Int32, UnsafeMutablePointer<Int32>?) -> OpaquePointer?
    typealias Encode = @convention(c) (OpaquePointer?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    typealias CtlInt = @convention(c) (OpaquePointer?, Int32, Int32) -> Int32
    typealias CtlPointer = @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<Int32>?) -> Int32
    typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    let create: Create, encodeFloat: Encode, ctlInt: CtlInt, ctlPointer: CtlPointer, destroyEncoder: Destroy

    struct Missing: Error { let what: String }

    init(_ path: String) throws {
        guard let module = path.withCString(encodedAs: UTF16.self, { LoadLibraryW($0) }) else { throw Missing(what: path) }
        func find<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let p = GetProcAddress(module, name) else { throw Missing(what: name) }
            return unsafeBitCast(p, to: type)
        }
        create = try find("opus_encoder_create", Create.self)
        encodeFloat = try find("opus_encode_float", Encode.self)
        ctlInt = try find("opus_encoder_ctl", CtlInt.self)
        ctlPointer = try find("opus_encoder_ctl", CtlPointer.self)
        destroyEncoder = try find("opus_encoder_destroy", Destroy.self)
    }

    /// The Windows recorder's settings: OPUS_APPLICATION_AUDIO, the bitrate, VBR unconstrained, complexity 10.
    func fileEncoder(channels: Int, bitrate: Int) throws -> OpaquePointer {
        var error: Int32 = 0
        guard let e = create(48000, Int32(channels), 2049, &error), error == 0 else { throw Missing(what: "encoder \(error)") }
        _ = ctlInt(e, 4002, Int32(bitrate))   // OPUS_SET_BITRATE
        _ = ctlInt(e, 4006, 1)                // OPUS_SET_VBR
        _ = ctlInt(e, 4020, 0)                // OPUS_SET_VBR_CONSTRAINT
        _ = ctlInt(e, 4010, 10)               // OPUS_SET_COMPLEXITY
        return e
    }

    func lookahead(_ e: OpaquePointer) -> Int {
        var value: Int32 = 0
        _ = ctlPointer(e, 4027, &value)       // OPUS_GET_LOOKAHEAD
        return Int(value)
    }

    func encode(_ e: OpaquePointer, _ frame: [Float], channels: Int) -> [UInt8]? {
        var packet = [UInt8](repeating: 0, count: 4000)
        let n = frame.withUnsafeBufferPointer { f in
            packet.withUnsafeMutableBufferPointer { encodeFloat(e, f.baseAddress, Int32(frame.count / channels), $0.baseAddress, 4000) }
        }
        return n > 0 ? Array(packet.prefix(Int(n))) : nil
    }

    func destroy(_ e: OpaquePointer) { destroyEncoder(e) }
}
#endif
