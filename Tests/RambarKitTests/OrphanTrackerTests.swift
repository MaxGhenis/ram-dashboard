import XCTest
@testable import RambarKit

final class OrphanTrackerTests: XCTestCase {
    private func scan(_ samples: [ProcessSample], _ tracker: inout OrphanTracker) -> OrphanReport {
        tracker.update(samples: samples, trees: buildSessionTrees(samples))
    }

    func testHelperSurvivingClosedSessionReportedAfterGracePeriod() {
        var tracker = OrphanTracker()
        let full = Fixture.machine
        _ = scan(full, &tracker)

        // Session 202 dies; its node child 203 reparents to launchd and lives on.
        var after = full.filter { $0.pid != 202 && $0.pid != 203 }
        after.append(Fixture.process(203, 1, Fixture.node, mb: 120))

        let first = scan(after, &tracker)
        XCTAssertEqual(first.count, 0, "one observation is inside the grace period")

        let second = scan(after, &tracker)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.newlyDetected, 1)
        XCTAssertEqual(second.footprint, 120 * 1_048_576)

        let third = scan(after, &tracker)
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(third.newlyDetected, 0, "standing orphans must not re-alert")
    }

    func testHelperThatExitsDuringGraceIsNeverReported() {
        var tracker = OrphanTracker()
        let full = Fixture.machine
        _ = scan(full, &tracker)

        var detached = full.filter { $0.pid != 202 && $0.pid != 203 }
        detached.append(Fixture.process(203, 1, Fixture.node, mb: 120))
        _ = scan(detached, &tracker)

        let gone = full.filter { $0.pid != 202 && $0.pid != 203 }
        let report = scan(gone, &tracker)
        XCTAssertEqual(report.count, 0)
    }

    func testChildDetachingWhileRootAliveIsCaught() {
        var tracker = OrphanTracker()
        let full = Fixture.machine
        _ = scan(full, &tracker)

        // node 103 reparents to launchd while engine 102 keeps running.
        var after = full.filter { $0.pid != 103 }
        after.append(Fixture.process(103, 1, Fixture.node, mb: 200))

        _ = scan(after, &tracker)
        let report = scan(after, &tracker)
        XCTAssertEqual(report.count, 1)
        XCTAssertTrue(report.identities.contains(ProcessIdentity(pid: 103, start: 1_000)))
    }

    func testReusedPidWithNewStartTimeIsNotAnOrphan() {
        var tracker = OrphanTracker()
        let full = Fixture.machine
        _ = scan(full, &tracker)

        // Session 202 and child 203 both die; an unrelated process is born
        // with the recycled pid 203 and a later start time.
        var after = full.filter { $0.pid != 202 && $0.pid != 203 }
        after.append(Fixture.process(203, 1, Fixture.python, mb: 500, start: 2_000))

        _ = scan(after, &tracker)
        let report = scan(after, &tracker)
        XCTAssertEqual(report.count, 0, "pid reuse must not inherit orphan candidacy")
    }

    func testAdoptedOrphanStopsBeingReported() {
        var tracker = OrphanTracker()
        let full = Fixture.machine
        _ = scan(full, &tracker)

        var detached = full.filter { $0.pid != 103 }
        detached.append(Fixture.process(103, 1, Fixture.node, mb: 200))
        _ = scan(detached, &tracker)
        XCTAssertEqual(scan(detached, &tracker).count, 1)

        // The same process (same start time) re-enters a session tree.
        let report = scan(full, &tracker)
        XCTAssertEqual(report.count, 0)
    }
}
