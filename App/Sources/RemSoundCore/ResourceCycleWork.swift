import Foundation
enum ResourceCycleWork {
    private static let maximumBudget=120.0
    private static let maximumAssertions=10_000
    static func run(budget:Double,clock:()->Double={ProcessInfo.processInfo.systemUptime},
        cancelled:()->Bool={false},execute:(CoreSelfCheck.ID)throws->Int=CoreSelfCheck.check)->ResourceCycleCheck.WorkReceipt {
        var items=0
        func receipt(_ passed:Bool)->ResourceCycleCheck.WorkReceipt { .init(passed:passed,quiescent:true,items:items) }
        guard budget.isFinite,budget>0,budget<=maximumBudget else { return receipt(false) }
        if cancelled() { return receipt(true) }
        let began=clock(),deadline=began+budget
        guard began.isFinite,began>=0,deadline.isFinite,deadline>began else { return receipt(false) }
        var previous=began
        // Each synchronous check scopes and retires its ring/codec before returning or throwing.
        // No sleep, device, Session, timer or network fallback fills a requested work budget.
        while items<ResourceCycleCheck.maximumWorkItems {
            if cancelled() { return receipt(true) }
            let now=clock()
            guard now.isFinite,now>=previous else { return receipt(false) }
            previous=now
            if now>=deadline { return receipt(true) }
            do {
                let assertions=try execute(items.isMultiple(of:2) ? .ring:.opus)
                guard (1...maximumAssertions).contains(assertions) else { return receipt(false) }
            } catch { return receipt(false) }
            items += 1
            let finished=clock()
            guard finished.isFinite,finished>=previous else { return receipt(false) }
            previous=finished
            if cancelled() { return receipt(true) }
            if finished>=deadline { return receipt(true) }
        }
        // The coordinator labels an early item-cap return incomplete; no fabricated elapsed time.
        return receipt(true)
    }
}
