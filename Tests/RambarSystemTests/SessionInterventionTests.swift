import XCTest
@testable import RambarKit
@testable import RambarSystem

final class SessionInterventionTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 1,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return predicate()
    }

    private func sessionSamples(
        stoppedPIDs: Set<Int32> = []
    ) -> [ProcessSample] {
        [
            ProcessSample(
                pid: 100,
                ppid: 1,
                execPath: "/Users/dev/.local/share/claude/versions/2.1.217",
                footprint: 10,
                startTime: 1_000,
                isStopped: stoppedPIDs.contains(100)
            ),
            ProcessSample(
                pid: 101,
                ppid: 100,
                execPath: "/opt/homebrew/bin/node",
                footprint: 20,
                startTime: 1_001,
                isStopped: stoppedPIDs.contains(101)
            ),
            ProcessSample(
                pid: 200,
                ppid: 1,
                execPath: "/Users/dev/.cargo/bin/codex",
                footprint: 30,
                startTime: 2_000
            ),
        ]
    }

    private func interventionState(
        stoppedPIDs: Set<Int32>
    ) throws -> SessionTreeInterventionState {
        let tree = try XCTUnwrap(
            buildSessionTrees(sessionSamples(stoppedPIDs: stoppedPIDs))
                .first { $0.root.pid == 100 }
        )
        return sessionTreeInterventionState(tree)
    }

    func testRootStoppedWhileChildRunningYieldsPartial() throws {
        let state = try interventionState(stoppedPIDs: [100])

        XCTAssertEqual(state.status, .partiallyStopped)
        XCTAssertEqual(state.stoppedProcessCount, 1)
        XCTAssertEqual(state.runningProcessCount, 1)
    }

    func testResumeLeavingStoppedChildYieldsPartial() throws {
        let state = try interventionState(stoppedPIDs: [101])

        XCTAssertEqual(state.status, .partiallyStopped)
        XCTAssertEqual(state.stoppedProcessCount, 1)
        XCTAssertEqual(state.runningProcessCount, 1)
    }

    func testFullStopYieldsStopped() throws {
        let state = try interventionState(stoppedPIDs: [100, 101])

        XCTAssertEqual(state.status, .stopped)
        XCTAssertEqual(state.stoppedProcessCount, 2)
        XCTAssertEqual(state.runningProcessCount, 0)
    }

    func testFullyRunningTreeYieldsRunning() throws {
        let state = try interventionState(stoppedPIDs: [])

        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.stoppedProcessCount, 0)
        XCTAssertEqual(state.runningProcessCount, 2)
    }

    func testTerminalForegroundMismatchRequiresControllingTerminal() {
        XCTAssertTrue(ProcessTerminalState(
            processGroupID: 100,
            foregroundProcessGroupID: 200,
            hasControllingTerminal: true
        ).isInBackgroundProcessGroup)
        XCTAssertFalse(ProcessTerminalState(
            processGroupID: 100,
            foregroundProcessGroupID: 100,
            hasControllingTerminal: true
        ).isInBackgroundProcessGroup)
        XCTAssertFalse(ProcessTerminalState(
            processGroupID: 100,
            foregroundProcessGroupID: 200,
            hasControllingTerminal: false
        ).isInBackgroundProcessGroup)
    }

    func testPauseSignalsOnlyExactSessionMembers() {
        let samples = sessionSamples()
        let trees = buildSessionTrees(samples)
        var sent: [(Int32, Int32)] = []

        let result = performSessionIntervention(
            root: ProcessIdentity(pid: 100, start: 1_000),
            action: .pause,
            trees: trees,
            identityLookup: { pid in samples.first { $0.pid == pid }?.identity },
            sendSignal: { pid, signal in sent.append((pid, signal)); return 0 }
        )

        XCTAssertTrue(result.foundSession)
        XCTAssertEqual(result.targetedProcessCount, 2)
        XCTAssertEqual(result.signaledProcessCount, 2)
        XCTAssertTrue(result.completedAllTargets)
        XCTAssertEqual(result.missedProcessCount, 0)
        XCTAssertEqual(sent.map(\.0), [100, 101])
        XCTAssertEqual(sent.map(\.1), [SIGSTOP, SIGSTOP])
    }

    func testInterruptTargetsOnlyRoot() {
        let samples = sessionSamples()
        var sent: [(Int32, Int32)] = []

        let result = performSessionIntervention(
            root: ProcessIdentity(pid: 100, start: 1_000),
            action: .interrupt,
            trees: buildSessionTrees(samples),
            identityLookup: { pid in samples.first { $0.pid == pid }?.identity },
            sendSignal: { pid, signal in sent.append((pid, signal)); return 0 }
        )

        XCTAssertEqual(result.signaledProcessCount, 1)
        XCTAssertEqual(sent.map(\.0), [100])
        XCTAssertEqual(sent.map(\.1), [SIGINT])
    }

    func testTerminateSendsTermThenContinueToStoppedTree() {
        let samples = sessionSamples()
        var sent: [(Int32, Int32)] = []

        let result = performSessionIntervention(
            root: ProcessIdentity(pid: 100, start: 1_000),
            action: .terminate,
            trees: buildSessionTrees(samples),
            identityLookup: { pid in samples.first { $0.pid == pid }?.identity },
            sendSignal: { pid, signal in sent.append((pid, signal)); return 0 }
        )

        XCTAssertEqual(result.signaledProcessCount, 2)
        XCTAssertEqual(sent.map { "\($0.0):\($0.1)" }, [
            "100:\(SIGTERM)", "101:\(SIGTERM)",
            "100:\(SIGCONT)", "101:\(SIGCONT)",
        ])
    }

    func testForceTerminateSendsKillWithoutContinue() {
        let samples = sessionSamples()
        var sent: [(Int32, Int32)] = []

        let result = performSessionIntervention(
            root: ProcessIdentity(pid: 100, start: 1_000),
            action: .forceTerminate,
            trees: buildSessionTrees(samples),
            identityLookup: { pid in samples.first { $0.pid == pid }?.identity },
            sendSignal: { pid, signal in sent.append((pid, signal)); return 0 }
        )

        XCTAssertEqual(result.signaledProcessCount, 2)
        XCTAssertEqual(sent.map { "\($0.0):\($0.1)" }, [
            "100:\(SIGKILL)", "101:\(SIGKILL)",
        ])
    }

    func testPidReuseIsSkippedAtSignalTime() {
        let samples = sessionSamples()
        var sent: [(Int32, Int32)] = []

        let result = performSessionIntervention(
            root: ProcessIdentity(pid: 100, start: 1_000),
            action: .pause,
            trees: buildSessionTrees(samples),
            identityLookup: { pid in
                pid == 101
                    ? ProcessIdentity(pid: 101, start: 9_999)
                    : samples.first { $0.pid == pid }?.identity
            },
            sendSignal: { pid, signal in sent.append((pid, signal)); return 0 }
        )

        XCTAssertEqual(result.signaledProcessCount, 1)
        XCTAssertEqual(result.staleProcessCount, 1)
        XCTAssertEqual(result.missedProcessCount, 0)
        XCTAssertFalse(result.completedAllTargets)
        XCTAssertEqual(sent.map(\.0), [100])
    }

    func testFailedChildMakesInterventionIncomplete() {
        let samples = sessionSamples()

        let result = performSessionIntervention(
            root: ProcessIdentity(pid: 100, start: 1_000),
            action: .pause,
            trees: buildSessionTrees(samples),
            identityLookup: { pid in samples.first { $0.pid == pid }?.identity },
            sendSignal: { pid, _ in pid == 101 ? -1 : 0 }
        )

        XCTAssertEqual(result.targetedProcessCount, 2)
        XCTAssertEqual(result.signaledProcessCount, 1)
        XCTAssertEqual(result.failedProcessCount, 1)
        XCTAssertEqual(result.staleProcessCount, 0)
        XCTAssertEqual(result.missedProcessCount, 0)
        XCTAssertFalse(result.completedAllTargets)
    }

    func testStaleRootAbortsBeforeAnyChildSignal() {
        let samples = sessionSamples()
        var sent: [(Int32, Int32)] = []

        let result = performSessionIntervention(
            root: ProcessIdentity(pid: 100, start: 1_000),
            action: .pause,
            trees: buildSessionTrees(samples),
            identityLookup: { pid in
                pid == 100
                    ? ProcessIdentity(pid: 100, start: 9_999)
                    : samples.first { $0.pid == pid }?.identity
            },
            sendSignal: { pid, signal in sent.append((pid, signal)); return 0 }
        )

        XCTAssertEqual(result.signaledProcessCount, 0)
        XCTAssertEqual(result.staleProcessCount, 1)
        XCTAssertEqual(result.missedProcessCount, 1)
        XCTAssertFalse(result.completedAllTargets)
        XCTAssertTrue(sent.isEmpty)
    }

    func testMissingRootSignalsNothing() {
        let samples = sessionSamples()
        var signals = 0
        let result = performSessionIntervention(
            root: ProcessIdentity(pid: 999, start: 1),
            action: .pause,
            trees: buildSessionTrees(samples),
            identityLookup: { _ in nil },
            sendSignal: { _, _ in signals += 1; return 0 }
        )
        XCTAssertFalse(result.foundSession)
        XCTAssertEqual(signals, 0)
    }

    func testValidatedSignalRefusesWrongStartTimeOnDisposableProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let pid = Int32(process.processIdentifier)
        let live = try XCTUnwrap(processIdentity(pid: pid))
        let wrong = ProcessIdentity(pid: pid, start: live.start + 1)

        XCTAssertFalse(validatedSignal(wrong, signal: SIGTERM))
        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(validatedSignal(live, signal: SIGTERM))
        process.waitUntilExit()
    }

    func testPauseResumeAndTerminateDisposableProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGCONT)
                process.terminate()
            }
        }

        let pid = Int32(process.processIdentifier)
        let identity = try XCTUnwrap(processIdentity(pid: pid))
        let syntheticSample = ProcessSample(
            pid: pid,
            ppid: 1,
            execPath: "/Users/dev/.local/share/claude/versions/2.1.217",
            footprint: 1,
            startTime: identity.start
        )
        let trees = buildSessionTrees([syntheticSample])

        let paused = performSessionIntervention(
            root: identity,
            action: .pause,
            trees: trees,
            identityLookup: processIdentity,
            sendSignal: kill
        )
        XCTAssertEqual(paused.signaledProcessCount, 1)
        XCTAssertTrue(waitUntil { processIsStopped(identity) == true })

        let resumed = performSessionIntervention(
            root: identity,
            action: .resume,
            trees: trees,
            identityLookup: processIdentity,
            sendSignal: kill
        )
        XCTAssertEqual(resumed.signaledProcessCount, 1)
        XCTAssertTrue(waitUntil { processIsStopped(identity) == false })

        let terminated = performSessionIntervention(
            root: identity,
            action: .terminate,
            trees: trees,
            identityLookup: processIdentity,
            sendSignal: kill
        )
        XCTAssertEqual(terminated.signaledProcessCount, 1)
        process.waitUntilExit()
    }

    func testForceTerminateStoppedDisposableProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()

        let pid = Int32(process.processIdentifier)
        defer {
            if process.isRunning {
                _ = kill(pid, SIGKILL)
                process.waitUntilExit()
            }
        }

        let identity = try XCTUnwrap(processIdentity(pid: pid))
        let trees = buildSessionTrees([ProcessSample(
            pid: pid,
            ppid: 1,
            execPath: "/Users/dev/.local/share/claude/versions/2.1.217",
            footprint: 1,
            startTime: identity.start
        )])

        _ = performSessionIntervention(
            root: identity,
            action: .pause,
            trees: trees,
            identityLookup: processIdentity,
            sendSignal: kill
        )
        XCTAssertTrue(waitUntil { processIsStopped(identity) == true })

        let terminated = performSessionIntervention(
            root: identity,
            action: .forceTerminate,
            trees: trees,
            identityLookup: processIdentity,
            sendSignal: kill
        )

        XCTAssertEqual(terminated.signaledProcessCount, 1)
        XCTAssertTrue(waitUntil { processIdentity(pid: pid) == nil })
        process.waitUntilExit()
    }

    func testGracefulThenForceTerminateResistantStoppedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
        try process.run()

        let pid = Int32(process.processIdentifier)
        defer {
            if process.isRunning {
                _ = kill(pid, SIGKILL)
                process.waitUntilExit()
            }
        }

        let identity = try XCTUnwrap(processIdentity(pid: pid))
        let trees = buildSessionTrees([ProcessSample(
            pid: pid,
            ppid: 1,
            execPath: "/Users/dev/.local/share/claude/versions/2.1.217",
            footprint: 1,
            startTime: identity.start
        )])

        _ = performSessionIntervention(
            root: identity,
            action: .pause,
            trees: trees,
            identityLookup: processIdentity,
            sendSignal: kill
        )
        XCTAssertTrue(waitUntil { processIsStopped(identity) == true })

        _ = performSessionIntervention(
            root: identity,
            action: .terminate,
            trees: trees,
            identityLookup: processIdentity,
            sendSignal: kill
        )
        XCTAssertTrue(
            waitUntil { processIsStopped(identity) == false },
            "graceful End should continue a stopped process so TERM can be handled"
        )
        XCTAssertNotNil(
            processIdentity(pid: pid),
            "a TERM-resistant process must remain visible for explicit Force End"
        )

        _ = performSessionIntervention(
            root: identity,
            action: .forceTerminate,
            trees: trees,
            identityLookup: processIdentity,
            sendSignal: kill
        )
        XCTAssertTrue(waitUntil { processIdentity(pid: pid) == nil })
        process.waitUntilExit()
    }
}
