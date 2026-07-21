import XCTest
@testable import RambarSystem
@testable import RambarKit

final class SessionIndexTests: XCTestCase {
    func testEncodingMatchesLiveLayout() {
        // Verified live: /Users/x/.axiom-worktrees/y → -Users-x--axiom-worktrees-y
        XCTAssertEqual(
            SessionIndex.encodeClaudeProjectDirectory(cwd: "/Users/x/.axiom-worktrees/y"),
            "-Users-x--axiom-worktrees-y"
        )
        XCTAssertEqual(
            SessionIndex.encodeClaudeProjectDirectory(cwd: "/Users/x"),
            "-Users-x"
        )
    }

    func testResolvesNewestTranscriptSinceRootStart() throws {
        let home = NSTemporaryDirectory() + "rambar-home-\(UUID().uuidString)"
        let projectDirectory = home + "/.claude/projects/-Users-x-proj"
        try FileManager.default.createDirectory(
            atPath: projectDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        let old = projectDirectory + "/old-session.jsonl"
        let current = projectDirectory + "/current-session.jsonl"
        FileManager.default.createFile(atPath: old, contents: Data())
        FileManager.default.createFile(atPath: current, contents: Data())
        let rootStart = Date().timeIntervalSince1970 - 300
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: rootStart - 3_600)], ofItemAtPath: old
        )

        let index = SessionIndex(home: home)
        XCTAssertEqual(
            index.sessionID(family: .claude, cwd: "/Users/x/proj", rootStart: rootStart),
            "current-session"
        )
        XCTAssertNil(
            index.sessionID(family: .claude, cwd: "/Users/x/other", rootStart: rootStart),
            "unknown project directory resolves to nil"
        )
        XCTAssertNil(index.sessionID(family: .codex, cwd: "/Users/x/proj", rootStart: rootStart))
    }

    func testSharedCwdSessionsGetNoID() {
        let engine = "/Users/dev/.local/share/claude/versions/1/claude"
        let samples = [
            ProcessSample(pid: 1, ppid: 0, execPath: "/sbin/launchd"),
            ProcessSample(pid: 10, ppid: 1, execPath: engine, cwd: "/Users/dev", footprint: 1, startTime: 5),
            ProcessSample(pid: 11, ppid: 1, execPath: engine, cwd: "/Users/dev", footprint: 1, startTime: 6),
            ProcessSample(pid: 12, ppid: 1, execPath: engine, cwd: "/Users/dev/proj", footprint: 1, startTime: 7),
        ]
        let unambiguous = keysWithUnambiguousCwd(buildSessionTrees(samples))
        XCTAssertEqual(unambiguous, ["claude:12:7"], "shared-cwd roots must not claim a transcript")
    }
}
