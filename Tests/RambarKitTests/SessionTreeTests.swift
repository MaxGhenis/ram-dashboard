import XCTest
@testable import RambarKit

final class SessionTreeTests: XCTestCase {
    func testFindsAllFourSessionsAcrossHostingModes() {
        let trees = buildSessionTrees(Fixture.machine)
        XCTAssertEqual(trees.count, 4)
        XCTAssertEqual(Set(trees.map(\.root.pid)), [102, 111, 202, 300])
    }

    func testDesktopHostedSessionGroupsEngineAndChildren() throws {
        let trees = buildSessionTrees(Fixture.machine)
        let alpha = try XCTUnwrap(trees.first { $0.root.pid == 102 })
        XCTAssertEqual(alpha.mode, .desktop)
        XCTAssertEqual(Set(alpha.members.map(\.pid)), [102, 103, 104])
        XCTAssertEqual(alpha.footprint, (400 + 200 + 2) * 1_048_576)
        XCTAssertEqual(alpha.projectName(home: Fixture.home), "alpha")
    }

    func testTmuxSessionClassifiedTerminal() throws {
        let trees = buildSessionTrees(Fixture.machine)
        let gamma = try XCTUnwrap(trees.first { $0.root.pid == 202 })
        XCTAssertEqual(gamma.mode, .terminal)
        XCTAssertEqual(gamma.processCount, 2)
    }

    func testLaneClassifiedHeadlessAndHomeCwdShownAsTilde() throws {
        let trees = buildSessionTrees(Fixture.machine)
        let lane = try XCTUnwrap(trees.first { $0.root.pid == 300 })
        XCTAssertEqual(lane.mode, .headless)
        XCTAssertEqual(lane.projectName(home: Fixture.home), "~")
        XCTAssertEqual(Set(lane.members.map(\.pid)), [300, 301])
    }

    func testDesktopUIAndItsHelpersAreNotMembers()  {
        let trees = buildSessionTrees(Fixture.machine)
        let allMembers = Set(trees.flatMap { $0.members.map(\.pid) })
        XCTAssertFalse(allMembers.contains(100), "Claude Desktop UI must not join any session")
        XCTAssertFalse(allMembers.contains(120), "renderer helper must not join any session")
        XCTAssertFalse(allMembers.contains(900), "Chrome must not join any session")
    }

    func testNestedEngineCountsIntoParentSession() throws {
        var samples = Fixture.machine
        // A subagent claude spawned inside session 102's tree.
        samples.append(Fixture.process(105, 104, Fixture.cliEngine, mb: 300))
        let trees = buildSessionTrees(samples)
        XCTAssertEqual(trees.count, 4, "nested engine must not become its own session")
        let alpha = try XCTUnwrap(trees.first { $0.root.pid == 102 })
        XCTAssertTrue(alpha.members.contains { $0.pid == 105 })
    }

    func testParentCycleDoesNotHang() {
        let cyclic = [
            Fixture.process(10, 11, Fixture.cliEngine, mb: 100),
            Fixture.process(11, 10, Fixture.node),
        ]
        let trees = buildSessionTrees(cyclic)
        XCTAssertEqual(trees.count, 1)
    }

    func testYoungerReusedPidRootCannotClaimOlderChild() throws {
        // Non-atomic sampling: child 30 was sampled with ppid 20, whose pid
        // was then reused by a NEWER engine. A real parent starts before its
        // child, so the edge must be rejected. (sol cross-family review)
        let samples = [
            Fixture.process(1, 0, Fixture.launchd, start: 0),
            Fixture.process(20, 1, Fixture.cliEngine, cwd: "/Users/dev/projects/new", mb: 300, start: 200),
            Fixture.process(30, 20, Fixture.node, mb: 500, start: 100),
        ]
        let trees = buildSessionTrees(samples)
        let root = try XCTUnwrap(trees.first { $0.root.pid == 20 })
        XCTAssertEqual(Set(root.members.map(\.pid)), [20],
                       "an older process must not be claimed through a reused pid")
    }

    func testMutualEngineCycleKeepsOlderRootWhenStartsDiffer() throws {
        // An apparent two-engine parent cycle (only possible from a racy
        // snapshot) must not drop the whole component: monotonic edges leave
        // the older engine as root, claiming the younger. (sol review)
        let samples = [
            Fixture.process(10, 11, Fixture.cliEngine, cwd: "/Users/dev/a", mb: 100, start: 100),
            Fixture.process(11, 10, Fixture.codexEngine, cwd: "/Users/dev/b", mb: 100, start: 200),
        ]
        let trees = buildSessionTrees(samples)
        XCTAssertEqual(trees.count, 1)
        let tree = try XCTUnwrap(trees.first)
        XCTAssertEqual(tree.root.pid, 10)
        XCTAssertEqual(Set(tree.members.map(\.pid)), [10, 11])
    }

    func testMutualEngineCycleWithEqualStartsDropsBoth() {
        // Documented residual: equal start times cannot be ordered, so an
        // equal-start mutual cycle disqualifies both engines for one scan.
        let samples = [
            Fixture.process(10, 11, Fixture.cliEngine, mb: 100, start: 100),
            Fixture.process(11, 10, Fixture.codexEngine, mb: 100, start: 100),
        ]
        XCTAssertEqual(buildSessionTrees(samples).count, 0)
    }

    func testSortedByFootprintDescending() {
        let footprints = buildSessionTrees(Fixture.machine).map(\.footprint)
        XCTAssertEqual(footprints, footprints.sorted(by: >))
    }

    func testAttentionThresholds() {
        XCTAssertFalse(sessionNeedsAttention(footprint: 1_073_741_824, processCount: 10))
        XCTAssertTrue(sessionNeedsAttention(footprint: 3 * 1_073_741_824, processCount: 1))
        XCTAssertTrue(sessionNeedsAttention(footprint: 0, processCount: 40))
    }
}
