import Foundation

/// Hardware-free workload observations, never a full application or leak acceptance verdict.
public struct ResourceCycleReport: Equatable, Sendable {
    private static let maximumResourceCount=1_000_000
    public enum Provenance:String,Sendable { case notCollected,nativeCurrentProcess,injected }
    public enum Termination:String,Sendable { case completed,cancelled,invalidBudget,invalidClock,deadline,incompleteCycle,workFailed,cleanupUnresolved,invalidReceipt }
    public struct Snapshot:Equatable,Sendable {
        public let residentBytes:UInt64?,threads:Int?,descriptors:Int?,cpuSeconds:Double?
        public init(residentBytes:UInt64?=nil,threads:Int?=nil,descriptors:Int?=nil,cpuSeconds:Double?=nil) {
            self.residentBytes=residentBytes;self.threads=threads;self.descriptors=descriptors;self.cpuSeconds=cpuSeconds
        }
    }
    public struct Observation:Equatable,Sendable {
        public let cycle:Int,elapsed:Double,snapshot:Snapshot,collectionFailed:Bool
        public init(cycle:Int,elapsed:Double,snapshot:Snapshot,collectionFailed:Bool=false) {
            self.cycle=cycle;self.elapsed=elapsed;self.snapshot=snapshot;self.collectionFailed=collectionFailed
        }
    }
    public struct Cycle:Equatable,Sendable {
        public let index:Int,elapsed:Double,items:Int
        public init(index:Int,elapsed:Double,items:Int) {self.index=index;self.elapsed=elapsed;self.items=items}
    }
    public struct Growth:Equatable,Sendable {
        public let residentBytes:Int64?,threads:Int?,descriptors:Int?,cpuSeconds:Double?
    }
    public let requestedSeconds:Int,provenance:Provenance,observations:[Observation],completed:[Cycle],termination:Termination
    public init(requestedSeconds:Int,provenance:Provenance,observations:[Observation],completed:[Cycle],termination:Termination) {
        self.requestedSeconds=requestedSeconds;self.provenance=provenance;self.observations=observations;self.completed=completed;self.termination=termination
    }
    public var fullAcceptance:Bool {false}
    public var isValid:Bool {
        guard observations.count<=ResourceCycleCheck.cycles+1,completed.count<=ResourceCycleCheck.cycles,
            (observations.isEmpty ? provenance == .notCollected:provenance != .notCollected),
            (6...120).contains(requestedSeconds) || termination == .invalidBudget else {return false}
        if termination == .invalidBudget {return observations.isEmpty && completed.isEmpty}
        guard completed.enumerated().allSatisfy({ index,value in
            value.index==index+1 && value.elapsed.isFinite && value.elapsed>0 && (1...ResourceCycleCheck.maximumWorkItems).contains(value.items)
        }),observations.enumerated().allSatisfy({ index,value in
            let snapshot=value.snapshot
            return value.cycle==index && value.elapsed.isFinite && value.elapsed>=0
                && (snapshot.threads.map {(1...Self.maximumResourceCount).contains($0)} ?? true)
                && (snapshot.descriptors.map {(0...Self.maximumResourceCount).contains($0)} ?? true)
                && (snapshot.cpuSeconds.map {$0.isFinite && $0>=0} ?? true)
                && (!value.collectionFailed || (snapshot.residentBytes==nil && snapshot.threads==nil && snapshot.descriptors==nil && snapshot.cpuSeconds==nil))
        }),zip(observations,observations.dropFirst()).allSatisfy({$0.elapsed<=$1.elapsed}) else {return false}
        if termination == .completed {
            return completed.count==ResourceCycleCheck.cycles && observations.count==ResourceCycleCheck.cycles+1
                && observations.dropFirst().allSatisfy {$0.elapsed>=Double(requestedSeconds)*Double($0.cycle)/Double(ResourceCycleCheck.cycles)}
        }
        return completed.count<ResourceCycleCheck.cycles && (observations.isEmpty ? completed.isEmpty:observations.count>=completed.count+1 && observations.count<=completed.count+2)
    }
    public var exitCode:Int {isValid ? rawReport.exitCode:1}
    public var growth:Growth {
        guard isValid else {return .init(residentBytes:nil,threads:nil,descriptors:nil,cpuSeconds:nil)}
        let value=rawReport.growth
        return .init(residentBytes:value.residentBytes,threads:value.threads,descriptors:value.descriptors,cpuSeconds:value.cpuSeconds)
    }
    private var rawReport:ResourceCycleCheck.Report {
        .init(observations:observations.map {.init(cycle:$0.cycle,elapsed:$0.elapsed,
            snapshot:.init(residentBytes:$0.snapshot.residentBytes,threads:$0.snapshot.threads,descriptors:$0.snapshot.descriptors,cpuSeconds:$0.snapshot.cpuSeconds),invalid:[],collectionFailed:$0.collectionFailed)},
            completed:completed.map {.init(index:$0.index,elapsed:$0.elapsed,items:$0.items)},termination:rawTermination)
    }
    private var rawTermination:ResourceCycleCheck.Termination {
        switch termination {
        case .completed:return .completed;case .cancelled:return .cancelled;case .invalidBudget:return .invalidBudget
        case .invalidClock:return .invalidClock;case .deadline:return .deadline;case .incompleteCycle:return .incompleteCycle
        case .workFailed:return .workFailed;case .cleanupUnresolved:return .cleanupUnresolved;case .invalidReceipt:return .invalidReceipt
        }
    }
}
public enum ProductResourceCycle {
    /// Synchronous cooperative memory workload and current-process observations; no physical I/O.
    public static func run(seconds:Int)->ResourceCycleReport {
        let raw=ResourceCycleCheck.run(seconds:seconds,clock:{ProcessInfo.processInfo.systemUptime},
            read:{OwnProcessMetrics.read().snapshot},work:{ResourceCycleWork.run(budget:$0)})
        let termination:ResourceCycleReport.Termination
        switch raw.termination {
        case .completed:termination = .completed;case .cancelled:termination = .cancelled;case .invalidBudget:termination = .invalidBudget
        case .invalidClock:termination = .invalidClock;case .deadline:termination = .deadline;case .incompleteCycle:termination = .incompleteCycle
        case .workFailed:termination = .workFailed;case .cleanupUnresolved:termination = .cleanupUnresolved;case .invalidReceipt:termination = .invalidReceipt
        }
        return .init(requestedSeconds:seconds,provenance:raw.observations.isEmpty ? .notCollected:.nativeCurrentProcess,
            observations:raw.observations.map {.init(cycle:$0.cycle,elapsed:$0.elapsed,
                snapshot:.init(residentBytes:$0.snapshot.residentBytes,threads:$0.snapshot.threads,descriptors:$0.snapshot.descriptors,cpuSeconds:$0.snapshot.cpuSeconds),collectionFailed:$0.collectionFailed)},
            completed:raw.completed.map {.init(index:$0.index,elapsed:$0.elapsed,items:$0.items)},termination:termination)
    }
}
