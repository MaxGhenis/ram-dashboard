import Foundation
import RambarKit

/// Resolves a session root to the agent's own session records on disk.
///
/// Claude Code keeps one directory per working directory under
/// ~/.claude/projects/, named by replacing "/" and "." with "-" (verified
/// against live directories, e.g. /Users/x/.axiom-worktrees/y →
/// -Users-x--axiom-worktrees-y), containing one .jsonl per session. The
/// transcript most recently written since the root started is that root's
/// session.
public struct SessionIndex {
    private let fileManager: FileManager
    private let claudeProjectsRoot: String

    public init(home: String, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.claudeProjectsRoot = home + "/.claude/projects"
    }

    public static func encodeClaudeProjectDirectory(cwd: String) -> String {
        String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    /// Best-effort session id (transcript filename stem) for a claude root.
    /// Codex and gemini roots return nil until their layouts are verified
    /// against live sessions.
    public func sessionID(family: AgentFamily, cwd: String?, rootStart: Double) -> String? {
        guard family == .claude, let cwd, !cwd.isEmpty else { return nil }
        let directory = claudeProjectsRoot + "/" + Self.encodeClaudeProjectDirectory(cwd: cwd)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return nil }

        var best: (stem: String, mtime: Double)?
        for entry in entries where entry.hasSuffix(".jsonl") {
            let path = directory + "/" + entry
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            let mtime = modified.timeIntervalSince1970
            // Written since the root started (small slack for clock skew).
            guard mtime >= rootStart - 60 else { continue }
            if best == nil || mtime > best!.mtime {
                best = (String(entry.dropLast(".jsonl".count)), mtime)
            }
        }
        return best?.stem
    }
}

/// Session keys whose root cwd is used by exactly one active session.
/// Transcript matching is ambiguous when several sessions share a working
/// directory (ccd sessions in $HOME, say) — those get no id rather than a
/// wrong one; the pid stands in.
public func keysWithUnambiguousCwd(_ trees: [AgentSessionTree]) -> Set<String> {
    var cwdCounts: [String: Int] = [:]
    for tree in trees {
        guard let cwd = tree.root.cwd else { continue }
        cwdCounts[cwd, default: 0] += 1
    }
    return Set(trees.compactMap { tree in
        guard let cwd = tree.root.cwd, cwdCounts[cwd] == 1 else { return nil }
        return tree.key
    })
}
