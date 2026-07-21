import Foundation
@testable import RambarKit

/// Synthesized process topologies mirroring the shapes observed live on a
/// desktop-app-heavy machine (2026-07-21 survey): a Claude Desktop UI hosting
/// engine sessions through disclaimer wrappers, a tmux-hosted CLI session, a
/// headless lane, and unrelated system processes.
enum Fixture {
    static let home = "/Users/dev"

    static let claudeDesktopUI = "/Applications/Claude.app/Contents/MacOS/Claude"
    static let claudeDesktopHelper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)"
    static let disclaimer = "/Applications/Claude.app/Contents/Helpers/disclaimer"
    static let desktopEngine = "/Users/dev/Library/Application Support/Claude/claude-code/2.1.215/claude.app/Contents/MacOS/claude"
    static let cliEngine = "/Users/dev/.local/share/claude/versions/2.1.215/claude"
    static let codexEngine = "/Users/dev/.cargo/bin/codex"
    static let node = "/opt/homebrew/bin/node"
    static let python = "/opt/homebrew/bin/python3.14"
    static let zsh = "/bin/zsh"
    static let tmux = "/opt/homebrew/bin/tmux"
    static let launchd = "/sbin/launchd"

    static func process(
        _ pid: Int32,
        _ ppid: Int32,
        _ execPath: String,
        script: String? = nil,
        cwd: String? = nil,
        mb footprintMB: UInt64 = 10,
        start: Double = 1_000
    ) -> ProcessSample {
        ProcessSample(
            pid: pid,
            ppid: ppid,
            execPath: execPath,
            scriptPath: script,
            cwd: cwd,
            footprint: footprintMB * 1_048_576,
            startTime: start
        )
    }

    /// launchd(1) → Claude.app UI(100) → disclaimer(101) → engine(102, 400MB)
    ///   → node MCP(103, 200MB), zsh(104, 2MB)
    /// plus a second engine session 110-chain, a desktop renderer helper (120),
    /// a tmux CLI session launchd→tmux(200)→zsh(201)→claude(202)→node(203),
    /// a headless lane launchd→claude(300)→python(301),
    /// and unrelated Chrome (900).
    static var machine: [ProcessSample] {
        [
            process(1, 0, launchd),
            process(100, 1, claudeDesktopUI, mb: 300),
            process(101, 100, disclaimer, mb: 1),
            process(102, 101, desktopEngine, cwd: "/Users/dev/projects/alpha", mb: 400),
            process(103, 102, node, script: "/Users/dev/mcp/alpha-server/index.js", mb: 200),
            process(104, 102, zsh, mb: 2),
            process(110, 100, disclaimer, mb: 1),
            process(111, 110, desktopEngine, cwd: "/Users/dev/projects/beta", mb: 350),
            process(112, 111, node, script: "/Users/dev/mcp/beta-server/index.js", mb: 150),
            process(120, 100, claudeDesktopHelper, mb: 180),
            process(200, 1, tmux, mb: 8),
            process(201, 200, zsh, mb: 3),
            process(202, 201, cliEngine, cwd: "/Users/dev/projects/gamma", mb: 500),
            process(203, 202, node, script: "/Users/dev/projects/gamma/dev-server.js", mb: 120),
            process(300, 1, cliEngine, cwd: home, mb: 250),
            process(301, 300, python, mb: 90),
            process(900, 1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", mb: 800),
        ]
    }
}
