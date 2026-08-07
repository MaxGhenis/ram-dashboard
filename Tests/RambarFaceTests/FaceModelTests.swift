import Foundation
import XCTest
import RambarKit
@testable import RambarSystem
@testable import RambarFace

@MainActor
final class FaceModelTests: XCTestCase {
    func testGroupByAppDefaultsToFalse() {
        withDefaults { defaults in
            XCTAssertFalse(FaceModel(defaults: defaults).groupByApp)
        }
    }

    func testGroupByAppPersistsRoundTrip() {
        withDefaults { defaults in
            let model = FaceModel(defaults: defaults)
            model.setGroupByApp(true)
            XCTAssertTrue(FaceModel(defaults: defaults).groupByApp)

            model.setGroupByApp(false)
            XCTAssertFalse(FaceModel(defaults: defaults).groupByApp)
        }
    }

    func testResumeFeedbackDoesNotClaimSuccessWhenProcessesRemainStopped() {
        let feedback = interventionFeedback(
            result: successfulInterventionResult,
            action: .resume,
            observedState: SessionTreeInterventionState(
                stoppedProcessCount: 14,
                runningProcessCount: 2
            ),
            terminalForegroundMismatch: true
        )

        XCTAssertEqual(
            feedback.message,
            "The terminal reclaimed this job. Open its original terminal and run `fg`."
        )
        XCTAssertFalse(feedback.requiresForceEnd)
    }

    func testGracefulEndFeedbackRequiresForceWhenSessionSurvives() {
        let feedback = interventionFeedback(
            result: successfulInterventionResult,
            action: .terminate,
            observedState: SessionTreeInterventionState(
                stoppedProcessCount: 14,
                runningProcessCount: 2
            ),
            terminalForegroundMismatch: true
        )

        XCTAssertEqual(
            feedback.message,
            "Session did not end gracefully. Use Force End to stop it immediately."
        )
        XCTAssertTrue(feedback.requiresForceEnd)
    }

    func testGracefulEndFeedbackSucceedsOnlyAfterSessionDisappears() {
        let feedback = interventionFeedback(
            result: successfulInterventionResult,
            action: .terminate,
            observedState: nil,
            terminalForegroundMismatch: false
        )

        XCTAssertEqual(feedback.message, "Session ended.")
        XCTAssertFalse(feedback.requiresForceEnd)
    }

    func testForceEndFeedbackRemainsAvailableWhenSessionSurvives() {
        let feedback = interventionFeedback(
            result: successfulInterventionResult,
            action: .forceTerminate,
            observedState: SessionTreeInterventionState(
                stoppedProcessCount: 14,
                runningProcessCount: 2
            ),
            terminalForegroundMismatch: true
        )

        XCTAssertEqual(
            feedback.message,
            "Force End did not remove the verified process tree."
        )
        XCTAssertTrue(feedback.requiresForceEnd)
    }

    private var successfulInterventionResult: SessionInterventionResult {
        SessionInterventionResult(
            foundSession: true,
            targetedProcessCount: 16,
            signaledProcessCount: 16,
            staleProcessCount: 0,
            failedProcessCount: 0
        )
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "FaceModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
