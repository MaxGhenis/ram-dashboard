import Foundation

/// The agent CLIs rambar attributes memory to.
public enum AgentFamily: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case gemini

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }
}

/// Classify an executable path as an agent engine, or nil.
///
/// Paths come from proc_pidpath, so they are full resolved binary paths —
/// there is no argv splitting and therefore no way for a space inside a path
/// to truncate the token (the bug class that made v1 match "Claude Helper"
/// processes).
///
/// Claude has three launch shapes, all verified against live processes:
/// - Desktop-hosted engine: …/Application Support/Claude/claude-code/<ver>/claude.app/Contents/MacOS/claude
/// - Standalone CLI: ~/.local/share/claude/versions/<ver>/claude (or any binary named claude)
/// - The Claude Desktop UI itself (/Applications/Claude.app/Contents/MacOS/Claude
///   and its Frameworks helpers) is NOT an engine and must not match.
public func agentFamily(forExecutablePath path: String) -> AgentFamily? {
    let lower = path.lowercased()
    let basename = (lower as NSString).lastPathComponent

    if basename == "claude" {
        // Desktop-hosted engine lives inside a claude.app bundle, but under a
        // claude-code versions directory — that component is the distinguisher
        // from the Claude Desktop UI binary, which is also named "claude"
        // case-insensitively and also sits at …/Contents/MacOS/.
        if lower.contains("/claude-code/") { return .claude }
        if lower.contains("claude.app/contents/macos") { return nil }
        return .claude
    }
    if basename == "codex" { return .codex }
    if basename == "gemini" { return .gemini }
    return nil
}
