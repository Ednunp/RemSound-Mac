import Foundation
import XCTest
@testable import RemSoundRuntime

final class SimulationLaunchTests: XCTestCase {
    func testWindowsReplayCommandIsAcceptedBeforeRuntimeStartup() throws {
        XCTAssertNoThrow(try LaunchOptions.parse(["--simulate","replay","--recording","/owned/recording.txt"]))
        XCTAssertNoThrow(try LaunchOptions.parse(["--simulator","replay","--recording","/owned/recording.txt"]))
    }
    func testFractionalDurationAndExplicitReplayParametersAreAccepted() throws {
        XCTAssertNoThrow(try LaunchOptions.parse(["--simulate","replay","--recording","/owned/recording.txt","--seconds","1.25","--stream","0","--one-way","5.5","--out","/owned/report"]))
    }
    func testInvalidOrMixedSimulationScopesRefuse() {
        for args in [
            ["--simulate","unknown","--recording","/r"], ["--simulate","replay"],
            ["--simulate","replay","--recording","relative"],
            ["--simulate","replay","--recording","/r","--simulate","replay"],
            ["--simulate","replay","--recording","/r","--seconds","nan"],
            ["--simulate","replay","--recording","/r","--seconds","0"],
            ["--simulate","replay","--recording","/r","--seconds","61"],
            ["--simulate","replay","--recording","/r","--stream","-2"],
            ["--simulate","replay","--recording","/r","--one-way","inf"],
            ["--simulate","replay","--recording","/r","--one-way","-1"],
            ["--simulate","replay","--recording","/r","--headless","--config-dir","/owned"],
            ["--simulate","replay","--recording","/r","--selftest"],
            ["--simulate","replay","--recording","/r","--profile","saved"],
            ["--recording","/r"], ["--stream","0"], ["--out","/owned"]
        ] { XCTAssertThrowsError(try LaunchOptions.parse(args),args.joined(separator:" ")) }
    }
}
