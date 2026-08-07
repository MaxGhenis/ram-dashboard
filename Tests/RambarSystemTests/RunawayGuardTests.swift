import XCTest
@testable import RambarKit
@testable import RambarSystem

final class RunawayGuardTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    private func tree(rootGB: UInt64, childGB: UInt64 = 0) -> AgentSessionTree {
        var samples = [
            ProcessSample(
                pid: 100,
                ppid: 1,
                execPath: "/Users/dev/.local/share/claude/versions/2.1.217",
                cwd: "/Users/dev/project",
                footprint: rootGB * gib,
                startTime: 1_000
            ),
        ]
        if childGB > 0 {
            samples.append(ProcessSample(
                pid: 101,
                ppid: 100,
                execPath: "/opt/homebrew/bin/node",
                footprint: childGB * gib,
                startTime: 1_001
            ))
        }
        return buildSessionTrees(samples)[0]
    }

    func testGuardIsDisabledByDefault() {
        XCTAssertEqual(RunawayGuard.automaticAction, .pause)
        var guardState = RunawayGuard()
        let incidents = guardState.evaluate(
            now: 100,
            totalMemory: 36 * gib,
            pressure: .critical,
            trees: [tree(rootGB: 20)],
            settings: .default
        )
        XCTAssertTrue(incidents.isEmpty)
    }

    func testAutomaticContainmentPausesOnlyLargestProcess() {
        let session = tree(rootGB: 1, childGB: 9)
        let largest = session.members.first { $0.pid == 101 }!
        let incident = RunawayIncident(
            sessionKey: session.key,
            root: session.root.identity,
            largestProcess: largest.identity,
            largestProcessFootprint: largest.footprint,
            sessionFootprint: session.footprint,
            reason: .rapidGrowth
        )
        var sent: [(Int32, Int32)] = []

        let result = performRunawayContainment(
            incident,
            identityLookup: { pid in session.members.first { $0.pid == pid }?.identity },
            sendSignal: { pid, signal in sent.append((pid, signal)); return 0 }
        )

        XCTAssertTrue(result.completedAllTargets)
        XCTAssertEqual(result.targetedProcessCount, 1)
        XCTAssertEqual(sent.map { "\($0.0):\($0.1)" }, ["101:\(SIGSTOP)"])
    }

    func testAutomaticContainmentDoesNotPauseChildAfterRootIdentityChanges() {
        let session = tree(rootGB: 1, childGB: 9)
        let largest = session.members.first { $0.pid == 101 }!
        let incident = RunawayIncident(
            sessionKey: session.key,
            root: session.root.identity,
            largestProcess: largest.identity,
            largestProcessFootprint: largest.footprint,
            sessionFootprint: session.footprint,
            reason: .rapidGrowth
        )
        var sent: [(Int32, Int32)] = []

        let result = performRunawayContainment(
            incident,
            identityLookup: { pid in
                if pid == session.root.pid {
                    return ProcessIdentity(pid: pid, start: 9_999)
                }
                return largest.identity
            },
            sendSignal: { pid, signal in sent.append((pid, signal)); return 0 }
        )

        XCTAssertFalse(result.foundSession)
        XCTAssertEqual(result.staleProcessCount, 1)
        XCTAssertTrue(sent.isEmpty)
    }

    func testLargeSessionTotalDoesNotTriggerWhenEachProcessIsBelowThreshold() {
        var guardState = RunawayGuard()
        let settings = RunawayGuardSettings(autoPauseEnabled: true)
        let session = tree(rootGB: 7, childGB: 7)

        XCTAssertTrue(guardState.evaluate(
            now: 100,
            totalMemory: 36 * gib,
            pressure: .critical,
            trees: [session],
            settings: settings
        ).isEmpty)
        XCTAssertTrue(guardState.evaluate(
            now: 105,
            totalMemory: 36 * gib,
            pressure: .critical,
            trees: [session],
            settings: settings
        ).isEmpty)
    }

    func testStableLargeProcessDoesNotTriggerUnderNormalPressure() {
        var guardState = RunawayGuard()
        let settings = RunawayGuardSettings(autoPauseEnabled: true)
        let session = tree(rootGB: 12)

        XCTAssertTrue(guardState.evaluate(
            now: 100,
            totalMemory: 36 * gib,
            pressure: .normal,
            trees: [session],
            settings: settings
        ).isEmpty)
        XCTAssertTrue(guardState.evaluate(
            now: 105,
            totalMemory: 36 * gib,
            pressure: .normal,
            trees: [session],
            settings: settings
        ).isEmpty)
    }

    func testLargeProcessUnderPressureRequiresTwoConsecutiveSamples() throws {
        var guardState = RunawayGuard()
        let settings = RunawayGuardSettings(autoPauseEnabled: true)
        let session = tree(rootGB: 12, childGB: 2)

        XCTAssertTrue(guardState.evaluate(
            now: 100,
            totalMemory: 36 * gib,
            pressure: .warn,
            trees: [session],
            settings: settings
        ).isEmpty)

        let incident = try XCTUnwrap(guardState.evaluate(
            now: 105,
            totalMemory: 36 * gib,
            pressure: .warn,
            trees: [session],
            settings: settings
        ).first)

        XCTAssertEqual(incident.sessionKey, session.key)
        XCTAssertEqual(incident.root, session.root.identity)
        XCTAssertEqual(incident.largestProcess, session.root.identity)
        XCTAssertEqual(incident.largestProcessFootprint, 12 * gib)
        XCTAssertEqual(incident.reason, .largeUnderPressure)
    }

    func testRapidGrowthTriggersUnderNormalPressureAndOnlyOnce() {
        var guardState = RunawayGuard()
        let settings = RunawayGuardSettings(autoPauseEnabled: true)

        XCTAssertTrue(guardState.evaluate(
            now: 100,
            totalMemory: 36 * gib,
            pressure: .normal,
            trees: [tree(rootGB: 4)],
            settings: settings
        ).isEmpty)
        XCTAssertTrue(guardState.evaluate(
            now: 105,
            totalMemory: 36 * gib,
            pressure: .normal,
            trees: [tree(rootGB: 9)],
            settings: settings
        ).isEmpty)

        let incidents = guardState.evaluate(
            now: 110,
            totalMemory: 36 * gib,
            pressure: .normal,
            trees: [tree(rootGB: 9)],
            settings: settings
        )
        XCTAssertEqual(incidents.map(\.reason), [.rapidGrowth])
        guardState.markContained(sessionKey: incidents[0].sessionKey)
        XCTAssertTrue(guardState.evaluate(
            now: 115,
            totalMemory: 36 * gib,
            pressure: .critical,
            trees: [tree(rootGB: 15)],
            settings: settings
        ).isEmpty, "a contained session must not be paused repeatedly")
    }

    func testGrowthDoesNotCompareDifferentLargestProcesses() {
        func switchingTree(rootGB: UInt64, childGB: UInt64) -> AgentSessionTree {
            buildSessionTrees([
                ProcessSample(
                    pid: 100,
                    ppid: 1,
                    execPath: "/Users/dev/.local/share/claude/versions/2.1.217",
                    footprint: rootGB * gib,
                    startTime: 1_000
                ),
                ProcessSample(
                    pid: 101,
                    ppid: 100,
                    execPath: "/opt/homebrew/bin/node",
                    footprint: childGB * gib,
                    startTime: 1_001
                ),
            ])[0]
        }

        var guardState = RunawayGuard()
        let settings = RunawayGuardSettings(autoPauseEnabled: true)
        XCTAssertTrue(guardState.evaluate(
            now: 100,
            totalMemory: 36 * gib,
            pressure: .normal,
            trees: [switchingTree(rootGB: 4, childGB: 5)],
            settings: settings
        ).isEmpty)
        XCTAssertTrue(guardState.evaluate(
            now: 105,
            totalMemory: 36 * gib,
            pressure: .normal,
            trees: [switchingTree(rootGB: 9, childGB: 5)],
            settings: settings
        ).isEmpty)
        XCTAssertTrue(guardState.evaluate(
            now: 110,
            totalMemory: 36 * gib,
            pressure: .normal,
            trees: [switchingTree(rootGB: 9, childGB: 5)],
            settings: settings
        ).isEmpty)
    }

    func testSettingsRoundTripAndMissingFileDefaultsOff() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let path = directory.appendingPathComponent("guard.json").path
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(RunawayGuardSettings.load(from: path), .default)
        try RunawayGuardSettings(autoPauseEnabled: true).save(to: path)
        XCTAssertEqual(
            RunawayGuardSettings.load(from: path),
            RunawayGuardSettings(autoPauseEnabled: true)
        )
    }
}
