import Foundation

/// Serial synchronous coordinator. Work receipts must follow their exact resource retirement.
enum ResourceCycleCheck {
    static let cycles = 3
    static let maximumWorkItems = 4096
    private static let secondsRange = 6...120
    private static let maximumResourceCount = 1_000_000
    enum Field: CaseIterable { case residentBytes, threads, descriptors, cpuSeconds }
    struct Snapshot {
        let residentBytes: UInt64?, threads: Int?, descriptors: Int?, cpuSeconds: Double?
        init(residentBytes: UInt64? = nil, threads: Int? = nil, descriptors: Int? = nil, cpuSeconds: Double? = nil) {
            self.residentBytes=residentBytes;self.threads=threads;self.descriptors=descriptors;self.cpuSeconds=cpuSeconds
        }
    }
    struct Observation {
        let cycle: Int, elapsed: Double, snapshot: Snapshot, invalid: Set<Field>, collectionFailed: Bool
    }
    struct WorkReceipt { let passed: Bool, quiescent: Bool, items: Int }
    struct Cycle { let index: Int, elapsed: Double, items: Int }
    enum Termination { case completed, cancelled, invalidBudget, invalidClock, deadline, incompleteCycle, workFailed, cleanupUnresolved, invalidReceipt }
    struct Growth { let residentBytes: Int64?, threads: Int?, descriptors: Int?, cpuSeconds: Double? }
    struct Report {
        let observations: [Observation], completed: [Cycle], termination: Termination
        var fullAcceptance: Bool { false }
        var exitCode: Int {
            switch termination {
            case .completed, .cancelled, .incompleteCycle: return 3
            case .invalidBudget, .invalidClock, .deadline, .workFailed, .cleanupUnresolved, .invalidReceipt: return 1
            }
        }
        var completeMetrics: Bool {
            let value=growth
            return value.residentBytes != nil && value.threads != nil && value.descriptors != nil && value.cpuSeconds != nil
        }
        var growth: Growth {
            guard termination == .completed, completed.count == cycles, observations.count == cycles+1,
                let first=observations.first?.snapshot,let last=observations.last?.snapshot else {
                return .init(residentBytes:nil,threads:nil,descriptors:nil,cpuSeconds:nil)
            }
            func has(_ field:Field) -> Bool {
                observations.allSatisfy { item in
                    guard !item.collectionFailed, !item.invalid.contains(field) else { return false }
                    switch field {
                    case .residentBytes: return item.snapshot.residentBytes != nil
                    case .threads: return item.snapshot.threads != nil
                    case .descriptors: return item.snapshot.descriptors != nil
                    case .cpuSeconds: return item.snapshot.cpuSeconds != nil
                    }
                }
            }
            var bytes:Int64?,threads:Int?,descriptors:Int?,cpu:Double?
            if has(.residentBytes),let a=first.residentBytes,let b=last.residentBytes {
                if b >= a { bytes=Int64(exactly:b-a) }
                else if let value=Int64(exactly:a-b) { bytes = -value }
            }
            if has(.threads),let a=first.threads,let b=last.threads {
                let value=b.subtractingReportingOverflow(a);if !value.overflow { threads=value.partialValue }
            }
            if has(.descriptors),let a=first.descriptors,let b=last.descriptors {
                let value=b.subtractingReportingOverflow(a);if !value.overflow { descriptors=value.partialValue }
            }
            if has(.cpuSeconds),let a=first.cpuSeconds,let b=last.cpuSeconds {
                let values=observations.compactMap { $0.snapshot.cpuSeconds }
                if zip(values,values.dropFirst()).allSatisfy({ $0 <= $1 }), (b-a).isFinite { cpu=b-a }
            }
            return .init(residentBytes:bytes,threads:threads,descriptors:descriptors,cpuSeconds:cpu)
        }
    }
    static func run(seconds: Int = 15, clock: () -> Double,
        cancelled: () -> Bool = { false }, read: () throws -> Snapshot?, work: (Double) throws -> WorkReceipt) -> Report {
        var observations:[Observation]=[],completed:[Cycle]=[]
        func report(_ termination:Termination) -> Report { .init(observations:observations,completed:completed,termination:termination) }
        guard secondsRange.contains(seconds) else { return report(.invalidBudget) }
        if cancelled() { return report(.cancelled) }
        let began=clock();guard began.isFinite, began >= 0 else { return report(.invalidClock) }
        let targets=(1...cycles).map { began+Double(seconds)*Double($0)/Double(cycles) }
        guard zip([began]+Array(targets.dropLast()),targets).allSatisfy({ $1.isFinite && $1 > $0 }) else { return report(.invalidClock) }
        var previous=began
        func time() -> Double? {
            let now=clock();guard now.isFinite,now >= previous else { return nil };previous=now;return now
        }
        func capture(_ cycle:Int) -> Bool {
            let raw:Snapshot?
            do { raw=try read() } catch { raw=nil }
            guard let now=time() else { return false }
            let source=raw ?? Snapshot()
            var invalid=Set<Field>(),threads=source.threads,descriptors=source.descriptors,cpu=source.cpuSeconds
            if let value=threads, !(1...maximumResourceCount).contains(value) { invalid.insert(.threads);threads=nil }
            if let value=descriptors, !(0...maximumResourceCount).contains(value) { invalid.insert(.descriptors);descriptors=nil }
            if let value=cpu, !value.isFinite || value < 0 { invalid.insert(.cpuSeconds);cpu=nil }
            observations.append(.init(cycle:cycle,elapsed:now-began,snapshot:.init(residentBytes:source.residentBytes,threads:threads,descriptors:descriptors,cpuSeconds:cpu),invalid:invalid,collectionFailed:raw == nil))
            return true
        }
        guard capture(0) else { return report(.invalidClock) }
        for index in 1...cycles {
            if cancelled() { return report(.cancelled) }
            guard let start=time() else { return report(.invalidClock) }
            let target=targets[index-1]
            guard target.isFinite,start < target else { return report(.deadline) }
            let receipt:WorkReceipt
            do { receipt=try work(target-start) }
            catch { return report(.cleanupUnresolved) }
            guard receipt.quiescent else { return report(.cleanupUnresolved) }
            guard let ended=time() else { return report(.invalidClock) }
            // Only actual quiescence permits the after snapshot or another work construction.
            guard capture(index) else { return report(.invalidClock) }
            if !receipt.passed { return report(.workFailed) }
            guard (1...maximumWorkItems).contains(receipt.items) else { return report(.invalidReceipt) }
            if cancelled() { return report(.cancelled) }
            guard ended >= target else { return report(.incompleteCycle) }
            completed.append(.init(index:index,elapsed:ended-start,items:receipt.items))
        }
        return report(.completed)
    }
}
