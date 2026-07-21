import XCTest
@testable import RambarSystem
@testable import RambarKit

final class StoreTests: XCTestCase {
    private var path: String!
    private var store: Store!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "rambar-test-\(UUID().uuidString)/rambar.sqlite"
        store = try Store(path: path)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(
            atPath: (path as NSString).deletingLastPathComponent
        )
    }

    private func tree(pid: Int32, project: String, mb: UInt64, start: Double = 100) -> AgentSessionTree {
        let root = ProcessSample(
            pid: pid, ppid: 1,
            execPath: "/Users/dev/.local/share/claude/versions/1/claude",
            cwd: "/Users/dev/projects/\(project)",
            footprint: mb * 1_048_576,
            startTime: start
        )
        return buildSessionTrees([ProcessSample(pid: 1, ppid: 0, execPath: "/sbin/launchd"), root])
            .first { $0.root.pid == pid }!
    }

    func testRecordAndReadBackActiveSessions() throws {
        let alpha = tree(pid: 50, project: "alpha", mb: 400)
        try store.record(ts: 1_000, trees: [alpha], sessionIDs: [alpha.key: "abc123"], home: "/Users/dev")

        let sessions = store.activeSessions(now: 1_005)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].project, "alpha")
        XCTAssertEqual(sessions[0].footprint, 400 * 1_048_576)
        XCTAssertEqual(sessions[0].sessionID, "abc123")
        XCTAssertEqual(sessions[0].mode, .headless)
        XCTAssertEqual(sessions[0].firstSeen, 1_000)
    }

    func testUpsertPreservesFirstSeenAndSessionID() throws {
        let alpha = tree(pid: 50, project: "alpha", mb: 400)
        try store.record(ts: 1_000, trees: [alpha], sessionIDs: [alpha.key: "abc123"], home: "/Users/dev")
        try store.record(ts: 1_005, trees: [alpha], sessionIDs: [:], home: "/Users/dev")

        let session = store.activeSessions(now: 1_006)[0]
        XCTAssertEqual(session.firstSeen, 1_000)
        XCTAssertEqual(session.lastSeen, 1_005)
        XCTAssertEqual(session.sessionID, "abc123", "a missed lookup must not erase a known id")
    }

    func testStaleSessionsExcluded() throws {
        let alpha = tree(pid: 50, project: "alpha", mb: 400)
        try store.record(ts: 1_000, trees: [alpha], sessionIDs: [:], home: "/Users/dev")
        XCTAssertEqual(store.activeSessions(now: 1_100).count, 0)
    }

    func testHistoryAndSlope() throws {
        let alpha = tree(pid: 50, project: "alpha", mb: 100)
        for step in 0..<10 {
            let grown = tree(pid: 50, project: "alpha", mb: 100 + UInt64(step) * 10)
            try store.record(ts: Double(step) * 5, trees: [grown], sessionIDs: [:], home: "/Users/dev")
        }
        let history = store.sessionHistory(key: alpha.key, since: 0)
        XCTAssertEqual(history.count, 10)
        XCTAssertTrue(isRising(slopeBytesPerSecond: footprintSlope(history)))
    }

    func testSystemRoundTripAndEvents() throws {
        let snapshot = SystemMemorySnapshot(
            total: 128 * 1_073_741_824, used: 100 * 1_073_741_824,
            free: 10 * 1_073_741_824, compressed: 4 * 1_073_741_824, pressure: .warn
        )
        try store.record(ts: 2_000, system: snapshot)
        try store.recordEvent(ts: 2_001, kind: "pressure", payload: #"{"to":"warn"}"#)

        let system = try XCTUnwrap(store.latestSystem())
        XCTAssertEqual(system.pressure, .warn)
        XCTAssertEqual(system.used, 100 * 1_073_741_824)

        let events = store.events(since: 2_000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, "pressure")
        XCTAssertTrue(store.events(since: 2_001).isEmpty, "since is exclusive")
    }

    func testCompactionDownsamplesOldRawSamples() throws {
        let now = 1_000_000.0
        let alpha = tree(pid: 50, project: "alpha", mb: 100)
        // 24 samples at 5s cadence, three hours old → should collapse to 1/minute.
        for step in 0..<24 {
            try store.record(
                ts: now - 3 * 3_600 + Double(step) * 5,
                trees: [alpha], sessionIDs: [:], home: "/Users/dev"
            )
        }
        // Fresh samples stay raw.
        for step in 0..<6 {
            try store.record(
                ts: now - 30 + Double(step) * 5,
                trees: [alpha], sessionIDs: [:], home: "/Users/dev"
            )
        }
        try store.compact(now: now)

        let history = store.sessionHistory(key: alpha.key, since: 0)
        let old = history.filter { $0.time < now - 7_200 }
        let fresh = history.filter { $0.time >= now - 7_200 }
        // 24 samples over 120s starting at :40 touch three minute buckets.
        XCTAssertEqual(old.count, 3, "old raw samples collapse to one per minute")
        XCTAssertEqual(fresh.count, 6)
    }
}
