import Darwin
import Foundation
import XCTest
@testable import RemSoundCore

final class NativeResourceCheckTests: XCTestCase {
    private func calls(taskBytes: Int32 = Int32(MemoryLayout<proc_taskinfo>.size),
        probe: Int32 = 32, lists: [[Int32]] = [[0,1,2],[0,1,2]], cpuOK: Bool = true,
        userSeconds: Int = 2, micros: Int32 = 250_000) -> OwnProcessMetrics.Calls {
        var read = 0
        return .init(task: { value in
            value.pointee.pti_resident_size = 123_456; value.pointee.pti_threadnum = 4; return taskBytes
        }, descriptors: { buffer, size in
            guard let buffer else { return probe }
            let fds = lists[min(read,lists.count-1)]; read += 1
            for (i,fd) in fds.enumerated() where (i+1)*MemoryLayout<proc_fdinfo>.stride <= Int(size) {
                buffer[i].proc_fd = fd; buffer[i].proc_fdtype = 1
            }
            return Int32(fds.count*MemoryLayout<proc_fdinfo>.stride)
        }, usage: { value in
            value.pointee.ru_utime.tv_sec = userSeconds; value.pointee.ru_utime.tv_usec = micros
            value.pointee.ru_stime.tv_sec = 1; return cpuOK ? 0 : -1
        })
    }
    func testInjectedMetricsHaveExplicitProvenanceAndUnits() {
        let result = OwnProcessMetrics.read(calls:calls())
        XCTAssertEqual(result.provenance,.injected)
        XCTAssertEqual(result.snapshot.residentBytes,123_456)
        XCTAssertEqual(result.snapshot.threads,4)
        XCTAssertEqual(result.snapshot.descriptors,3)
        XCTAssertEqual(result.snapshot.cpuSeconds,3.25)
    }
    func testShortTaskReplyNeverPublishesPartialStructure() {
        let result = OwnProcessMetrics.read(calls:calls(taskBytes:1))
        XCTAssertNil(result.snapshot.residentBytes); XCTAssertNil(result.snapshot.threads)
        XCTAssertEqual(result.snapshot.cpuSeconds,3.25)
    }
    func testDescriptorCapPrecedesBufferFactory() {
        var fills=0
        let c=OwnProcessMetrics.Calls(task:{_ in 0},descriptors:{buffer,_ in
            if buffer != nil { fills += 1 }; return Int32.max
        },usage:{_ in -1})
        XCTAssertNil(OwnProcessMetrics.read(calls:c).snapshot.descriptors); XCTAssertEqual(fills,0)
    }
    func testDescriptorInvalidProbeNeverFills() {
        for probe:Int32 in [-1,0,1,33] {
            XCTAssertNil(OwnProcessMetrics.read(calls:calls(probe:probe)).snapshot.descriptors)
        }
    }
    func testChangingDescriptorInventoryIsUnavailable() {
        XCTAssertNil(OwnProcessMetrics.read(calls:calls(lists:[[0,1,2],[0,1,3]])).snapshot.descriptors)
        XCTAssertNil(OwnProcessMetrics.read(calls:calls(lists:[[0,1,2],[0,1]])).snapshot.descriptors)
    }
    func testDuplicateNegativeAndFullDescriptorRepliesRefuse() {
        for fds:[Int32] in [[0,0,2],[-1,1,2],[0,1,2,3]] {
            XCTAssertNil(OwnProcessMetrics.read(calls:calls(lists:[fds])).snapshot.descriptors)
        }
    }
    func testFailedOrInvalidCPUTimeStaysMissing() {
        XCTAssertNil(OwnProcessMetrics.read(calls:calls(cpuOK:false)).snapshot.cpuSeconds)
        XCTAssertNil(OwnProcessMetrics.read(calls:calls(userSeconds:-1)).snapshot.cpuSeconds)
        XCTAssertNil(OwnProcessMetrics.read(calls:calls(micros:1_000_000)).snapshot.cpuSeconds)
        XCTAssertNil(OwnProcessMetrics.read(calls:calls(userSeconds:Int.max)).snapshot.cpuSeconds)
    }
    func testThreadPlaceholderIsUnavailable() {
        var c=calls();c.task={p in p.pointee.pti_threadnum=0; return Int32(MemoryLayout<proc_taskinfo>.size)}
        XCTAssertNil(OwnProcessMetrics.read(calls:c).snapshot.threads)
    }
    func testNativeOwnProcessObservationIsSeparate() {
        let result=OwnProcessMetrics.read()
        XCTAssertEqual(result.provenance,.nativeCurrentProcess)
        XCTAssertGreaterThan(result.snapshot.residentBytes ?? 0,0)
        XCTAssertGreaterThan(result.snapshot.threads ?? 0,0)
        XCTAssertNotNil(result.snapshot.cpuSeconds)
        // A changing descriptor inventory may be unavailable; it must never be invented.
        if let count=result.snapshot.descriptors { XCTAssertGreaterThan(count,0) }
    }
    func testWorkConsumesBudgetThroughActualItems() {
        var time=10.0,work:[CoreSelfCheck.ID]=[]
        let result=ResourceCycleWork.run(budget:1,clock:{time},execute:{id in work.append(id);time += 0.25;return 1})
        XCTAssertTrue(result.passed && result.quiescent);XCTAssertEqual(result.items,4)
        XCTAssertEqual(work,[.ring,.opus,.ring,.opus]);XCTAssertEqual(time,11)
    }
    func testWorkInvalidBudgetOrClockNeverConstructs() {
        var calls=0
        for budget in [0.0,-1,.infinity,.nan,121] {
            XCTAssertFalse(ResourceCycleWork.run(budget:budget,execute:{_ in calls += 1;return 1}).passed)
        }
        for clock in [-1.0,.nan,.infinity,Double.greatestFiniteMagnitude] {
            XCTAssertFalse(ResourceCycleWork.run(budget:1,clock:{clock},execute:{_ in calls += 1;return 1}).passed)
        }
        XCTAssertEqual(calls,0)
    }
    func testWorkCancellationBeforeAndAfterNativeReceipt() {
        var cancel=true,calls=0,time=1.0
        let first=ResourceCycleWork.run(budget:1,cancelled:{cancel},execute:{_ in calls += 1;return 1})
        XCTAssertTrue(first.quiescent);XCTAssertEqual(first.items,0)
        cancel=false
        let late=ResourceCycleWork.run(budget:1,clock:{time},cancelled:{cancel},execute:{_ in calls += 1;time += 0.2;cancel=true;return 1})
        XCTAssertTrue(late.quiescent);XCTAssertEqual(late.items,1);XCTAssertEqual(calls,1)
    }
    func testWorkFailureAndInvalidAssertionsStopIndependentItems() {
        for assertions in [0,-1,10_001] {
            var calls=0
            let result=ResourceCycleWork.run(budget:1,execute:{_ in calls += 1;return assertions})
            XCTAssertFalse(result.passed);XCTAssertTrue(result.quiescent);XCTAssertEqual(calls,1)
        }
        enum Failure:Error { case synthetic }
        let thrown=ResourceCycleWork.run(budget:1,execute:{_ in throw Failure.synthetic})
        XCTAssertFalse(thrown.passed);XCTAssertTrue(thrown.quiescent)
    }
    func testWorkBackwardClockAndItemCapCannotLoop() {
        var time=1.0
        let backward=ResourceCycleWork.run(budget:1,clock:{time},execute:{_ in time=0;return 1})
        XCTAssertFalse(backward.passed);XCTAssertEqual(backward.items,1)
        var calls=0
        let cap=ResourceCycleWork.run(budget:1,clock:{1},execute:{_ in calls += 1;return 1})
        XCTAssertTrue(cap.quiescent);XCTAssertEqual(calls,ResourceCycleCheck.maximumWorkItems)
        XCTAssertEqual(cap.items,ResourceCycleCheck.maximumWorkItems)
    }
    func testActualNativeCodecRingCycleIsQuiescent() {
        let began=ProcessInfo.processInfo.systemUptime
        let receipt=ResourceCycleWork.run(budget:0.05)
        XCTAssertTrue(receipt.passed && receipt.quiescent);XCTAssertGreaterThan(receipt.items,0)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime-began,0.05)
    }
    func testActualOwnProcessResourceCycleReportsPartialScope() {
        let report=ResourceCycleCheck.run(seconds:6,clock:{ProcessInfo.processInfo.systemUptime},
            read:{OwnProcessMetrics.read().snapshot},work:{ResourceCycleWork.run(budget:$0)})
        XCTAssertEqual(report.termination,.completed);XCTAssertEqual(report.exitCode,3)
        XCTAssertFalse(report.fullAcceptance);XCTAssertEqual(report.observations.count,4)
        XCTAssertEqual(report.completed.count,3)
        XCTAssertTrue(report.completed.allSatisfy { $0.items>0 && $0.items<=ResourceCycleCheck.maximumWorkItems })
        let values=report.observations.map { item -> [String:Any] in
            ["elapsed":item.elapsed,"residentBytes":item.snapshot.residentBytes as Any? ?? NSNull(),
             "threads":item.snapshot.threads as Any? ?? NSNull(),"descriptors":item.snapshot.descriptors as Any? ?? NSNull(),
             "cpuSeconds":item.snapshot.cpuSeconds as Any? ?? NSNull()]
        }
        if let data=try? JSONSerialization.data(withJSONObject:values,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8) {
            print("NATIVE-OWN-PROCESS-OBSERVATIONS "+text)
        }
    }
    func testDescriptorReprobeGrowthRefusesStableLookingPrefix() {
        var c=calls(),probes=0;let original=c.descriptors
        c.descriptors={buffer,size in
            if buffer == nil { probes += 1;return probes==1 ? 32:40 };return original(buffer,size)
        }
        XCTAssertNil(OwnProcessMetrics.read(calls:c).snapshot.descriptors)
    }
    func testMalformedDescriptorFillBytesRefuse() {
        for reply:Int32 in [-1,0,1,33,64] {
            var c=calls();c.descriptors={buffer,_ in buffer == nil ? 32:reply}
            XCTAssertNil(OwnProcessMetrics.read(calls:c).snapshot.descriptors)
        }
    }
    func testDescriptorTypeReplacementRefusesSameNumber() {
        var c=calls(),fills=0;let original=c.descriptors
        c.descriptors={buffer,size in
            let result=original(buffer,size)
            if let buffer { fills += 1;buffer[0].proc_fdtype=UInt32(fills) }
            return result
        }
        XCTAssertNil(OwnProcessMetrics.read(calls:c).snapshot.descriptors)
    }
    func testInventoryOrderChangesDoNotInventGrowth() {
        XCTAssertEqual(OwnProcessMetrics.read(calls:calls(lists:[[0,1,2],[2,0,1]])).snapshot.descriptors,3)
    }
    func testWorkLateNonfiniteClockFailsBeforeAnotherItem() {
        var time=1.0,calls=0
        let receipt=ResourceCycleWork.run(budget:1,clock:{time},execute:{_ in calls += 1;time = .nan;return 1})
        XCTAssertFalse(receipt.passed);XCTAssertTrue(receipt.quiescent);XCTAssertEqual(calls,1)
    }
    func testWorkFailureWinsCancellationReceipt() {
        var cancel=false
        let receipt=ResourceCycleWork.run(budget:1,cancelled:{cancel},execute:{_ in cancel=true;return 0})
        XCTAssertFalse(receipt.passed);XCTAssertTrue(receipt.quiescent)
    }
    func testNativeDescriptorObservationSeesOnlyOwnedPipeChurn() throws {
        let before=try XCTUnwrap(OwnProcessMetrics.read().snapshot.descriptors)
        var descriptors:[Int32]=[-1,-1]
        XCTAssertEqual(pipe(&descriptors),0)
        guard descriptors.allSatisfy({$0>=0}) else { return }
        let during=OwnProcessMetrics.read().snapshot.descriptors
        for fd in descriptors { XCTAssertEqual(close(fd),0) }
        let after=OwnProcessMetrics.read().snapshot.descriptors
        XCTAssertEqual(during,before+2);XCTAssertEqual(after,before)
    }
}
