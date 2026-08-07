import XCTest
import RambarKit
import RambarSystem
@testable import RambarFace

final class EndSessionConfirmationTests: XCTestCase {
    func testRequestRetainsSessionWhenDialogPresentationStateClearsFirst() {
        let session = SessionRecord(
            key: "claude:4242:1",
            family: .claude,
            project: "hedy_mobile",
            cwd: "/tmp/hedy_mobile",
            mode: .headless,
            rootPid: 4242,
            rootStart: 1,
            sessionID: "session-id",
            title: "Review Intercom conversation",
            firstSeen: 1,
            lastSeen: 2,
            footprint: 3,
            processCount: 4
        )
        var pending: EndSessionConfirmationRequest? =
            EndSessionConfirmationRequest(session: session)

        // macOS dismisses a confirmation dialog before invoking its button
        // action, which clears the view's presentation state.
        let presentedRequest = pending
        pending = nil

        var confirmedKey: String?
        var confirmedAction: SessionInterventionAction?
        presentedRequest?.perform { session, action in
            confirmedKey = session.key
            confirmedAction = action
        }

        XCTAssertNil(pending)
        XCTAssertEqual(confirmedKey, session.key)
        XCTAssertEqual(confirmedAction, .terminate)
    }

    func testForceRequestRetainsForceTerminateAction() {
        let session = SessionRecord(
            key: "claude:4242:1",
            family: .claude,
            project: "hedy_mobile",
            cwd: "/tmp/hedy_mobile",
            mode: .headless,
            rootPid: 4242,
            rootStart: 1,
            sessionID: "session-id",
            title: "Review Intercom conversation",
            firstSeen: 1,
            lastSeen: 2,
            footprint: 3,
            processCount: 4
        )
        let request = EndSessionConfirmationRequest(session: session, force: true)

        var confirmedAction: SessionInterventionAction?
        request.perform { _, action in confirmedAction = action }

        XCTAssertEqual(confirmedAction, .forceTerminate)
    }
}
