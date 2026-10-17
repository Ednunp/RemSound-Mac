import Darwin
import Foundation
enum OwnProcessMetrics {
    private static let maximumThreadCount=1_000_000
    private static let microsecondsPerSecond=1_000_000
    enum Provenance { case nativeCurrentProcess, injected }
    struct Measurement { let snapshot:ResourceCycleCheck.Snapshot;let provenance:Provenance }
    struct Calls {
        var task:(UnsafeMutablePointer<proc_taskinfo>)->Int32
        var descriptors:(UnsafeMutablePointer<proc_fdinfo>?,Int32)->Int32
        var usage:(UnsafeMutablePointer<rusage>)->Int32
    }
    static func read(calls:Calls?=nil)->Measurement {
        let provenance:Provenance=calls == nil ? .nativeCurrentProcess:.injected
        let api=calls ?? nativeCalls()
        var task=proc_taskinfo(),usage=rusage()
        let taskSize=Int32(MemoryLayout<proc_taskinfo>.size)
        let taskOK=api.task(&task) == taskSize
        let cpuOK=api.usage(&usage) == 0
        let threads=taskOK && (1...maximumThreadCount).contains(Int(task.pti_threadnum)) ? Int(task.pti_threadnum):nil
        return .init(snapshot:.init(residentBytes:taskOK ? task.pti_resident_size:nil,
            threads:threads,descriptors:descriptorCount(api),cpuSeconds:cpuOK ? cpuSeconds(usage):nil),provenance:provenance)
    }
    private static let maximumDescriptors=4096
    private static func nativeCalls()->Calls {
        // There is deliberately no caller-supplied PID or process discovery.
        let pid=getpid()
        return .init(task:{proc_pidinfo(pid,PROC_PIDTASKINFO,0,$0,Int32(MemoryLayout<proc_taskinfo>.size))},
            descriptors:{proc_pidinfo(pid,PROC_PIDLISTFDS,0,$0,$1)},usage:{getrusage(RUSAGE_SELF,$0)})
    }
    private static func descriptorCount(_ api:Calls)->Int? {
        let stride=MemoryLayout<proc_fdinfo>.stride
        let bytes=api.descriptors(nil,0)
        // Apple's sizing reply includes capacity/margin, not the open descriptor count.
        guard bytes>0,Int(bytes)%stride==0,Int(bytes)/stride<=maximumDescriptors else { return nil }
        let capacity=Int(bytes)/stride
        func inventory()->[(Int32,UInt32)]? {
            var buffer=[proc_fdinfo](repeating:proc_fdinfo(),count:capacity)
            let used=buffer.withUnsafeMutableBufferPointer { api.descriptors($0.baseAddress,bytes) }
            // A full buffer may be truncated. Zero/error and malformed byte counts are unavailable.
            guard used>0,used<bytes,Int(used)%stride==0 else { return nil }
            var seen=Set<Int32>(),result:[(Int32,UInt32)]=[]
            for entry in buffer.prefix(Int(used)/stride) {
                guard entry.proc_fd>=0,seen.insert(entry.proc_fd).inserted else { return nil }
                result.append((entry.proc_fd,entry.proc_fdtype))
            }
            return result.sorted { $0.0<$1.0 }
        }
        guard let first=inventory(),let second=inventory(),api.descriptors(nil,0)==bytes,
            first.count==second.count,zip(first,second).allSatisfy({$0.0.0==$0.1.0 && $0.0.1==$0.1.1}) else { return nil }
        return first.count
    }
    private static func cpuSeconds(_ value:rusage)->Double? {
        let user=value.ru_utime,system=value.ru_stime
        guard user.tv_sec>=0,system.tv_sec>=0,(0..<microsecondsPerSecond).contains(Int(user.tv_usec)),
            (0..<microsecondsPerSecond).contains(Int(system.tv_usec)) else { return nil }
        let (seconds,overflow)=user.tv_sec.addingReportingOverflow(system.tv_sec)
        guard !overflow else { return nil }
        let result=Double(seconds)+(Double(user.tv_usec)+Double(system.tv_usec))/Double(microsecondsPerSecond)
        return result.isFinite ? result:nil
    }
}
