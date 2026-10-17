import Foundation
import XCTest
@testable import RemSoundCore

final class ProductTestPackTests: XCTestCase {
    func testCatalogPinsEveryActualWindowsRegistrationExactlyOnce() {
        XCTAssertEqual(ProductTestPack.names.count,545)
        XCTAssertEqual(Set(ProductTestPack.names).count,545)
        XCTAssertTrue(ProductTestPack.names.contains(ProductTestPack.knownAnswers))
    }
    func testFullAndFeatureKeepMissingBehaviorUnverifiedAndFailTheGate() {
        for pack in [ProductTestPack.Pack.full,.feature] {
            let result=ProductTestPack.run(pack:pack,budget:8)
            XCTAssertEqual(result.catalogSteps,545)
            XCTAssertFalse(result.steps.isEmpty)
            XCTAssertEqual(result.steps.map(\.name),Array(ProductTestPack.names.prefix(result.steps.count)))
            XCTAssertFalse(result.steps.contains { $0.status == "FAIL" })
            if result.termination == "completed" {
                XCTAssertEqual(result.steps.count,545)
                XCTAssertEqual(result.steps.filter { $0.status == "UNVERIFIED" }.count,538)
            } else { XCTAssertEqual(result.termination,"deadline") }
            XCTAssertEqual(result.exitCode,1)
            XCTAssertFalse(result.startedUTC.isEmpty)
        }
    }
    func testNamedKnownAnswersRunsBothDirectionsThroughSharedProductionParsers() {
        let result=ProductTestPack.run(pack:.feature,only:ProductTestPack.knownAnswers)
        XCTAssertEqual(result.steps.count,1)
        guard let step=result.steps.first else { return }
        XCTAssertEqual(step.status,"PASS")
        XCTAssertEqual(result.selection,ProductTestPack.knownAnswers);XCTAssertEqual(result.catalogSteps,545)
        XCTAssertGreaterThanOrEqual(step.assertions,20)
        XCTAssertTrue(step.failures.isEmpty)
        XCTAssertEqual(result.exitCode,0)
    }
    func testUnknownNameAndInvalidBudgetNeverRunAnotherCheck() {
        let unknown=ProductTestPack.run(pack:.full,only:"not a catalog step")
        XCTAssertEqual(unknown.termination,"invalidSelection");XCTAssertTrue(unknown.steps.isEmpty)
        for budget in [0,-1,9,Double.nan,Double.infinity] {
            let report=ProductTestPack.run(pack:.full,budget:budget)
            XCTAssertEqual(report.termination,"invalidBudget");XCTAssertTrue(report.steps.isEmpty)
        }
    }
    func testStructuredReportIsBoundedValueFreeAndNotAPartialSuccess() throws {
        let report=ProductTestPack.run(pack:.full,budget:8)
        let bytes=try JSONEncoder().encode(report)
        XCTAssertLessThan(bytes.count,256*1024)
        let decoded=try JSONDecoder().decode(ProductTestPack.Report.self,from:bytes)
        XCTAssertEqual(decoded.catalogSteps,545)
        XCTAssertEqual(decoded.steps.map(\.name),Array(ProductTestPack.names.prefix(decoded.steps.count)))
        XCTAssertEqual(decoded.termination,report.termination)
        XCTAssertEqual(decoded.exitCode,1)
        let text=String(decoding:bytes,as:UTF8.self)
        XCTAssertFalse(text.contains("known answer\""))
        XCTAssertFalse(text.contains("/Users/"));XCTAssertFalse(text.contains("password-value"))
    }
    func testClockRegressionAndLateReturnCannotBecomeCompletedSuccess() {
        for sequence in [[1.0,0.0],[1.0,Double.nan],[1.0,1.0,10.0]] {
            var position=0
            let report=ProductTestPack.run(pack:.full,only:ProductTestPack.knownAnswers,budget:3,clock:{
                let value=sequence[min(position,sequence.count-1)];position += 1;return value
            })
            XCTAssertEqual(report.termination,sequence.count == 3 ? "deadline" : "invalidClock")
            XCTAssertEqual(report.exitCode,1)
        }
    }
    func testActualStructuredProductReportIsRetainedOnlyUnderIsolatedTestRoot() throws {
        let root=try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let report=ProductTestPack.run(pack:.full,budget:8)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        try encoder.encode(report).write(to:URL(fileURLWithPath:root).appendingPathComponent("named-product-report.json"),options:.atomic)
        XCTAssertEqual(report.exitCode,1)
    }
    func testFocusedPassCannotBeRelabeledAsCompleteOrDuplicatedCatalog() throws {
        let report=ProductTestPack.run(pack:.full,only:ProductTestPack.knownAnswers)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(report)) as? [String:Any])
        object.removeValue(forKey:"selection")
        func decoded(_ value:[String:Any]) throws -> ProductTestPack.Report {
            try JSONDecoder().decode(ProductTestPack.Report.self,from:JSONSerialization.data(withJSONObject:value))
        }
        XCTAssertEqual(try decoded(object).exitCode,1)
        let steps=try XCTUnwrap(object["steps"] as? [[String:Any]])
        object["steps"]=Array(repeating:steps[0],count:545)
        XCTAssertEqual(try decoded(object).exitCode,1)
        object["catalogSteps"]=1;object["steps"]=steps
        XCTAssertEqual(try decoded(object).exitCode,1)
    }
}
