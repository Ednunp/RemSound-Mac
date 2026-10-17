import AudioSupport
import Foundation
import XCTest
@testable import RemSoundCore

final class CallbackBudgetTests: XCTestCase {
    func testActualCallbackFramesDetermineBudgetAndKeepIndependentMaxima() throws {
        let ring = try XCTUnwrap(rs_ring_create(16))
        defer { rs_ring_destroy(ring) }
        XCTAssertEqual(rs_ring_callback_metrics_lock_free(ring), 1)
        rs_ring_note_callback_elapsed(ring, 1_000_000, 96, 48_000)
        rs_ring_note_callback_elapsed(ring, 3_000_000, 240, 48_000)
        rs_ring_note_callback_elapsed(ring, 1_500_000, 48, 48_000)
        let figures = rs_ring_callback_figures(ring)
        XCTAssertEqual(figures.callbacks, 3)
        XCTAssertEqual(figures.frames, 384)
        XCTAssertEqual(figures.elapsed_ns, 5_500_000)
        XCTAssertEqual(figures.budget_ns, 8_000_000)
        XCTAssertEqual(figures.max_elapsed_ns, 3_000_000)
        XCTAssertEqual(figures.max_load_ppm, 1_500_000)
        XCTAssertEqual(figures.over_budget, 1)
        XCTAssertEqual(rs_ring_available(ring), 0, "Observations must not write audio samples")
    }

    func testInvalidFrameRatesAreIgnoredAndRingsHaveSeparateLifetimes() throws {
        let first = try XCTUnwrap(rs_ring_create(16))
        let second = try XCTUnwrap(rs_ring_create(16))
        defer { rs_ring_destroy(first); rs_ring_destroy(second) }
        for rate in [0.0, -1, .nan, .infinity] {
            rs_ring_note_callback_elapsed(first, 100, 96, rate)
        }
        rs_ring_note_callback_elapsed(first, 100, 0, 48_000)
        XCTAssertEqual(rs_ring_callback_figures(first).callbacks, 0)
        rs_ring_note_callback_elapsed(first, 500_000, 48, 96_000)
        let figures = rs_ring_callback_figures(first)
        XCTAssertEqual(figures.budget_ns, 500_000)
        XCTAssertEqual(figures.max_load_ppm, 1_000_000)
        XCTAssertEqual(figures.over_budget, 0, "Equal to the deadline is not over it")
        XCTAssertEqual(rs_ring_callback_figures(second).callbacks, 0)
        rs_ring_note_callback_elapsed(second, 1_000_000, 48, 48_000)
        XCTAssertEqual(rs_ring_callback_figures(second).over_budget, 0,
                       "A deadline equality at the normal pipeline rate is not an overrun")
    }

    func testConcurrentReadersAndUpdatesDoNotLoseCompletedCallbacks() throws {
        let ring = try XCTUnwrap(rs_ring_create(16))
        defer { rs_ring_destroy(ring) }
        DispatchQueue.concurrentPerform(iterations: 4) { lane in
            for _ in 0..<1_000 {
                rs_ring_note_callback_elapsed(ring, UInt64((lane + 1) * 1_000), 48, 48_000)
                _ = rs_ring_callback_figures(ring)
            }
        }
        let figures = rs_ring_callback_figures(ring)
        XCTAssertEqual(figures.callbacks, 4_000)
        XCTAssertEqual(figures.frames, 192_000)
        XCTAssertEqual(figures.elapsed_ns, 10_000_000)
        XCTAssertEqual(figures.budget_ns, 4_000_000_000)
        XCTAssertEqual(figures.max_elapsed_ns, 4_000)
        XCTAssertEqual(figures.over_budget, 0)
    }

    func testMonotonicCallbackWrapperAndSnapshotFormatting() throws {
        let ring = try XCTUnwrap(rs_ring_create(16))
        defer { rs_ring_destroy(ring) }
        let began = rs_callback_begin()
        XCTAssertGreaterThan(began, 0)
        rs_ring_note_callback(ring, began, 48, 48_000)
        XCTAssertEqual(rs_ring_callback_figures(ring).callbacks, 1)
        let before = rs_ring_callback_figures(ring).callbacks
        rs_ring_note_callback(ring, UInt64.max, 48, 48_000)
        XCTAssertEqual(rs_ring_callback_figures(ring).callbacks, before)
        rs_ring_note_callback_elapsed(ring, 2_000_000, 48, 48_000)
        let summary = AudioCallbackBudget.description(rs_ring_callback_figures(ring), name: "Input")
        XCTAssertTrue(summary.contains("Input"))
        XCTAssertTrue(summary.contains("lifetime max load 200.000%"))
        XCTAssertTrue(summary.contains("wall execution"))
        XCTAssertTrue(summary.contains("not scheduling delay"))
    }
}
