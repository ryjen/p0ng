import XCTest
@testable import PongCore

/// Synthetic display cadence invariants. These are NOT measurements of
/// two-device RTT, frame presentation, battery use or input latency.
final class FramePacingRegressionTests: XCTestCase {
    private enum Scenario {
        static let simulationSeconds = 10
        static let fixedRefreshRatesHz = [30, 60, 90, 120]
        static let variableRefreshRatesHz: [Double] = [120, 48, 90, 60, 75]
        static let variableScheduleCycles = 120
        static let expectedTickToleranceSeconds = 1e-8
    }

    func testHostSimulationDurationDoesNotDependOnDisplayRefreshRate() {
        let expectedTicks = Int(Double(Scenario.simulationSeconds) / FrameStepper.step)

        for refreshHz in Scenario.fixedRefreshRatesHz {
            var stepper = FrameStepper()
            var simulatedTicks = 0
            let frames = Scenario.simulationSeconds * refreshHz

            for _ in 0..<frames {
                simulatedTicks += stepper.advance(elapsed: 1.0 / Double(refreshHz))
            }

            XCTAssertEqual(simulatedTicks, expectedTicks,
                           "\(refreshHz) Hz display cadence must not alter host simulation speed")
            XCTAssertEqual(stepper.discardedSeconds, 0, accuracy: 1e-9)
        }
    }

    func testSyntheticVariableCadenceDoesNotAccumulateSimulationDrift() {
        var stepper = FrameStepper()
        var simulatedTicks = 0
        var elapsedSeconds = 0.0

        for _ in 0..<Scenario.variableScheduleCycles {
            for refreshHz in Scenario.variableRefreshRatesHz {
                let elapsed = 1.0 / refreshHz
                elapsedSeconds += elapsed
                simulatedTicks += stepper.advance(elapsed: elapsed)
            }
        }

        let expectedTicks = Int((elapsedSeconds +
            Scenario.expectedTickToleranceSeconds) / FrameStepper.step)
        XCTAssertEqual(simulatedTicks, expectedTicks)
        XCTAssertEqual(stepper.discardedSeconds, 0, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(stepper.accumulator, -Scenario.expectedTickToleranceSeconds)
        XCTAssertLessThan(stepper.accumulator, FrameStepper.step)
    }
}
