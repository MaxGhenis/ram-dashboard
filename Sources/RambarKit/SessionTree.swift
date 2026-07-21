import Foundation

/// How a session is hosted, classified from its root's ancestry — not from
/// TTY state, which goes stale when terminals close and is absent for
/// desktop-app and SDK sessions entirely.
public enum SessionMode: String, Codable, Sendable {
    case desktop   // an ancestor is the Claude Desktop app
    case terminal  // an ancestor is a terminal emulator, tmux, or an editor
    case headless  // reached launchd without either marker (lanes, cron, SDK)

    public var label: String {
        switch self {
        case .desktop: return "desktop"
        case .terminal: return "terminal"
        case .headless: return "headless"
        }
    }
}

/// One agent session: an engine root plus every process descended from it.
public struct AgentSessionTree: Sendable {
    public let root: ProcessSample
    public let family: AgentFamily
    public let mode: SessionMode
    /// All member processes, root included.
    public let members: [ProcessSample]

    public var footprint: UInt64 { members.reduce(0) { $0 + $1.footprint } }
    public var processCount: Int { members.count }
    public var children: [ProcessSample] { members.filter { $0.pid != root.pid } }

    /// Stable key for persistence: family + root identity.
    public var key: String { "\(family.rawValue):\(root.pid):\(Int(root.startTime))" }

    /// Project label: last component of the root's working directory,
    /// with the home directory itself shown as "~".
    public func projectName(home: String) -> String {
        guard let cwd = root.cwd, !cwd.isEmpty else { return "unknown" }
        if cwd == home { return "~" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

private let terminalMarkers: Set<String> = [
    "tmux", "terminal", "iterm2", "ghostty", "wezterm-gui", "alacritty",
    "kitty", "warp", "rio", "hyper",
]

private func isTerminalAncestor(_ basename: String) -> Bool {
    if terminalMarkers.contains(basename) { return true }
    // Editor-hosted terminals (VS Code, Cursor) run engines under helper
    // processes; sessions there are interactive, not headless.
    return basename.hasPrefix("code helper") || basename.hasPrefix("cursor helper")
}

/// A parentage edge is only credible when the parent started no later than
/// the child — fork order guarantees it for true parents. Collection is not
/// atomic: a pid sampled as someone's ppid can die and be reused by a newer
/// process before the table is complete, and without this check the newer
/// process (possibly an engine root) would claim the older child.
private func isPlausibleParent(_ parent: ProcessSample, of child: ProcessSample) -> Bool {
    parent.startTime <= child.startTime
}

/// Group all processes into agent session trees.
///
/// Roots are engine processes with no engine ancestor; every process is
/// assigned to its nearest root ancestor (a claude engine spawned inside
/// another claude session counts into the parent session). Ancestry walks are
/// cycle-guarded and every edge must satisfy start-time monotonicity.
/// Sorted by footprint descending.
public func buildSessionTrees(_ samples: [ProcessSample]) -> [AgentSessionTree] {
    var byPid: [Int32: ProcessSample] = [:]
    for sample in samples where sample.pid > 0 {
        byPid[sample.pid] = byPid[sample.pid] ?? sample
    }

    func hasEngineAncestor(_ sample: ProcessSample) -> Bool {
        var child = sample
        var visited: Set<Int32> = [sample.pid]
        while child.ppid > 0, visited.insert(child.ppid).inserted,
              let parent = byPid[child.ppid], isPlausibleParent(parent, of: child) {
            if agentFamily(forExecutablePath: parent.execPath) != nil { return true }
            child = parent
        }
        return false
    }

    let roots = samples.filter { sample in
        sample.pid > 0
            && agentFamily(forExecutablePath: sample.execPath) != nil
            && !hasEngineAncestor(sample)
    }
    let rootPids = Set(roots.map(\.pid))

    var membersByRoot: [Int32: [ProcessSample]] = [:]
    for sample in samples where sample.pid > 0 {
        var current = sample
        var visited: Set<Int32> = []
        while visited.insert(current.pid).inserted {
            if rootPids.contains(current.pid) {
                membersByRoot[current.pid, default: []].append(sample)
                break
            }
            guard current.ppid > 0,
                  let parent = byPid[current.ppid],
                  isPlausibleParent(parent, of: current) else { break }
            current = parent
        }
    }

    func mode(of root: ProcessSample) -> SessionMode {
        var child = root
        var visited: Set<Int32> = [root.pid]
        while child.ppid > 0, visited.insert(child.ppid).inserted,
              let parent = byPid[child.ppid], isPlausibleParent(parent, of: child) {
            let lower = parent.execPath.lowercased()
            if lower.contains("/applications/claude.app/") { return .desktop }
            if isTerminalAncestor((lower as NSString).lastPathComponent) { return .terminal }
            child = parent
        }
        return .headless
    }

    return roots.compactMap { root -> AgentSessionTree? in
        guard let family = agentFamily(forExecutablePath: root.execPath),
              let members = membersByRoot[root.pid] else { return nil }
        return AgentSessionTree(root: root, family: family, mode: mode(of: root), members: members)
    }
    .sorted { $0.footprint > $1.footprint }
}

/// Session attention thresholds, shared by UI and diagnostics.
public let sessionFootprintWarningBytes: UInt64 = 3 * 1_073_741_824
public let sessionProcessCountWarning = 40

public func sessionNeedsAttention(footprint: UInt64, processCount: Int) -> Bool {
    footprint >= sessionFootprintWarningBytes || processCount >= sessionProcessCountWarning
}
