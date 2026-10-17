import AudioSupport
import Foundation

enum AudioCallbackBudget {
    static func describe(ring: OpaquePointer, name: String) -> String {
        guard rs_ring_callback_metrics_lock_free(ring) == 1 else {
            return "callback budget: \(name), unavailable: lock-free counters or monotonic timebase unavailable."
        }
        return description(rs_ring_callback_figures(ring), name: name)
    }
    static func description(_ figures: RSCallbackFigures, name: String) -> String {
        let count = Double(figures.callbacks)
        let mean = count > 0 ? String(format: "%.6f", Double(figures.elapsed_ns) / count / 1e6) : "unmeasured"
        let budget = count > 0 ? String(format: "%.6f", Double(figures.budget_ns) / count / 1e6) : "unmeasured"
        return "callback budget: \(name), ring lifetime callbacks \(figures.callbacks), "
            + "requested frames \(figures.frames), wall execution mean \(mean) ms, "
            + "lifetime max \(String(format: "%.6f", Double(figures.max_elapsed_ns) / 1e6)) ms, "
            + "mean frame/rate budget \(budget) ms, "
            + "lifetime max load \(String(format: "%.3f", Double(figures.max_load_ppm) / 10_000))%, "
            + "over budget \(figures.over_budget). Wall execution, not scheduling delay; "
            + "live atomic snapshot may span a completing callback."
    }
}
