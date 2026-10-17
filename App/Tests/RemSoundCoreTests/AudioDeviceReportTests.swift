import AudioToolbox
import CoreAudio
import Foundation
import XCTest
@testable import RemSoundCore

final class AudioDeviceReportTests: XCTestCase {
    private func format() -> AudioDeviceReportFormat {
        .init(sampleRate:48000,channels:2,bitsPerChannel:32,encoding:"float PCM")
    }
    private func source(ids:[UInt32] = [1,2]) -> AudioDeviceReportSource {
        .init(ids:{ids},defaultID:{$0 == .input ? 1 : 2},
            streams:{id,direction in (direction == .input && id == 1) || (direction == .output && id == 2) ? [id+10] : []},
            uid:{"uid-\($0)"},name:{"Device \($0)"},format:{_ in self.format()})
    }
    func testRefusalPrecedesEvenTheInjectedFactory() {
        var factories=0
        XCTAssertThrowsError(try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:false,makeSource:{factories += 1;return self.source()}))
        XCTAssertEqual(factories,0)
        XCTAssertThrowsError(try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:false))
    }
    func testOneSnapshotUsesReportedDefaultsAndDirectionStreams() throws {
        let report=try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true,makeSource:{self.source()})
        XCTAssertEqual(report.inputs.map(\.uid),["uid-1"]);XCTAssertEqual(report.outputs.map(\.uid),["uid-2"])
        let input=try XCTUnwrap(report.inputs.first),output=try XCTUnwrap(report.outputs.first)
        XCTAssertTrue(input.isDefault);XCTAssertTrue(output.isDefault)
        XCTAssertEqual(input.formats.first??.channels,2)
    }
    func testNoDevicesNeverInventsSystemDefaultPlaceholder() throws {
        let report=try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true,makeSource:{self.source(ids:[])})
        XCTAssertTrue(report.inputs.isEmpty);XCTAssertTrue(report.outputs.isEmpty)
    }
    func testMissingDefaultDoesNotMarkAnArbitraryDevice() throws {
        var s=source();s.defaultID={_ in nil}
        let r=try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true,makeSource:{s})
        XCTAssertFalse(try XCTUnwrap(r.inputs.first).isDefault);XCTAssertFalse(try XCTUnwrap(r.outputs.first).isDefault)
    }
    func testMissingFormatKeepsNamedStreamAsUnavailable() throws {
        var s=source();s.format={_ in nil}
        let r=try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true,makeSource:{s})
        let input=try XCTUnwrap(r.inputs.first);XCTAssertEqual(input.formats.count,1);XCTAssertNil(input.formats.first ?? nil)
    }
    func testDuplicateZeroAndExcessiveDeviceIDsFailBeforeMetadata() {
        for ids:[UInt32] in [[0],[1,1],Array(1...1025).map(UInt32.init)] {
            var s=source(ids:ids),metadata=0;s.name={_ in metadata += 1;return "device"}
            XCTAssertThrowsError(try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true,makeSource:{s}))
            XCTAssertEqual(metadata,0)
        }
    }
    func testOversizedOrDuplicateStreamListsRefuseBeforeFormats() {
        for streams:[UInt32] in [[0],[11,11],Array(1...257).map(UInt32.init)] {
            var s=source(ids:[1]),formats=0;s.streams={_,_ in streams};s.format={_ in formats += 1;return self.format()}
            XCTAssertThrowsError(try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true,makeSource:{s}))
            XCTAssertEqual(formats,0)
        }
    }
    func testMissingNamesAndDuplicateUIDsAreNotPartialInventorySuccess() {
        var s=source();s.name={_ in nil}
        XCTAssertThrowsError(try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true,makeSource:{s}))
        s=source();s.uid={_ in "same"};s.streams={id,_ in [id+10]}
        XCTAssertThrowsError(try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true,makeSource:{s}))
    }
    func testPropertyArrayRejectsOversizedOrChangedSizesBeforeParsing() {
        var reads=0
        XCTAssertNil(AudioDeviceCatalog.readReportArray(maximumCount:2,size:{12},read:{_,_ in reads += 1;return true}))
        XCTAssertNil(AudioDeviceCatalog.readReportArray(maximumCount:2,size:{5},read:{_,_ in reads += 1;return true}))
        XCTAssertEqual(reads,0)
        XCTAssertNil(AudioDeviceCatalog.readReportArray(maximumCount:2,size:{8},read:{_,bytes in bytes=12;return true}))
        XCTAssertNil(AudioDeviceCatalog.readReportArray(maximumCount:2,size:{8},read:{_,bytes in bytes=5;return true}))
    }
    func testPropertyArrayAllowsExactAndShrinkingResponsesAndZeroWithoutRead() {
        var reads=0
        XCTAssertEqual(AudioDeviceCatalog.readReportArray(maximumCount:2,size:{0},read:{_,_ in reads += 1;return true}),[])
        XCTAssertEqual(reads,0)
        let values=AudioDeviceCatalog.readReportArray(maximumCount:2,size:{8},read:{pointer,bytes in
            pointer.storeBytes(of:UInt32(11),as:UInt32.self);bytes=4;return true
        })
        XCTAssertEqual(values,[11])
        XCTAssertEqual(AudioDeviceCatalog.readReportArray(maximumCount:2,size:{8},read:{pointer,_ in
            pointer.storeBytes(of:UInt32(11),as:UInt32.self);pointer.storeBytes(of:UInt32(22),toByteOffset:4,as:UInt32.self);return true
        }),[11,22])
    }
    func testTotalStreamBudgetBoundsFormatQueriesAcrossDevices() {
        var s=source(ids:Array(1...33).map(UInt32.init)),formats=0
        s.streams={_,direction in direction == .input ? Array(1...256).map(UInt32.init) : []}
        s.format={_ in formats += 1;return nil}
        XCTAssertThrowsError(try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true,makeSource:{s}))
        XCTAssertEqual(formats,8192)
    }
    func testEnumerationAndStreamQueryErrorsAreNotEmptySuccess() {
        var s=source();s.ids={throw NSError(domain:"device fixture",code:1)}
        XCTAssertThrowsError(try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true,makeSource:{s}))
        s=source();s.streams={_,_ in throw NSError(domain:"device fixture",code:2)}
        XCTAssertThrowsError(try AudioDeviceCatalog.reportSnapshot(allowHardwareEnumeration:true,makeSource:{s}))
    }
    func testInvalidStreamFormatNeverInventsValidRateOrChannels() {
        var f=AudioStreamBasicDescription();f.mFormatID=kAudioFormatLinearPCM;f.mFormatFlags=kAudioFormatFlagIsFloat
        f.mSampleRate=48000;f.mChannelsPerFrame=2;f.mBitsPerChannel=32
        XCTAssertEqual(AudioDeviceCatalog.decodeReportFormat(f)?.encoding,"float PCM")
        f.mSampleRate = .nan;XCTAssertNil(AudioDeviceCatalog.decodeReportFormat(f))
        f.mSampleRate=48000;f.mChannelsPerFrame=0;XCTAssertNil(AudioDeviceCatalog.decodeReportFormat(f))
        f.mChannelsPerFrame=UInt32.max;XCTAssertNil(AudioDeviceCatalog.decodeReportFormat(f))
    }
}
