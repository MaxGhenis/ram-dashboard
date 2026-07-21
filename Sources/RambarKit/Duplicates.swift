import Foundation

/// The same helper binary resident many times across sessions — usually N
/// copies of one MCP server, each paying full price. A dedup opportunity
/// nothing else surfaces.
public struct DuplicateGroup: Sendable {
    /// scriptPath when the members are interpreter-run, else the binary path —
    /// two MCP servers that are both "node" must not merge.
    public let commandPath: String
    public let count: Int
    public let footprint: UInt64

    public var basename: String { (commandPath as NSString).lastPathComponent }
}

public func findDuplicates(
    in trees: [AgentSessionTree],
    minimumCount: Int = 3,
    minimumFootprint: UInt64 = 300 * 1_048_576
) -> [DuplicateGroup] {
    var byCommand: [String: (count: Int, footprint: UInt64)] = [:]
    for tree in trees {
        for child in tree.children {
            let key = child.scriptPath ?? child.execPath
            let entry = byCommand[key] ?? (0, 0)
            byCommand[key] = (entry.count + 1, entry.footprint + child.footprint)
        }
    }
    return byCommand
        .filter { $0.value.count >= minimumCount && $0.value.footprint >= minimumFootprint }
        .map { DuplicateGroup(commandPath: $0.key, count: $0.value.count, footprint: $0.value.footprint) }
        .sorted { $0.footprint > $1.footprint }
}
