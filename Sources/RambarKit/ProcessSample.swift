import Foundation

/// One process as observed at a sampling instant. The collector fills these
/// from libproc; tests fill them from fixtures. Everything downstream of this
/// type is a pure function.
public struct ProcessSample: Hashable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// Fully resolved executable path from proc_pidpath — never parsed from argv.
    public let execPath: String
    /// For interpreter-run processes (node, python, bun…), the script path
    /// from argv[1]; nil otherwise. Lets dedup distinguish two MCP servers
    /// that are both "node" at the binary level.
    public let scriptPath: String?
    public let cwd: String?
    /// Physical footprint in bytes (ri_phys_footprint), the same per-process
    /// attribution Activity Monitor's Memory column reports.
    public let footprint: UInt64
    /// Process start time, unix seconds. (pid, startTime) is the stable
    /// identity used everywhere; pid reuse gets a new startTime.
    public let startTime: Double

    public init(
        pid: Int32,
        ppid: Int32,
        execPath: String,
        scriptPath: String? = nil,
        cwd: String? = nil,
        footprint: UInt64 = 0,
        startTime: Double = 0
    ) {
        self.pid = pid
        self.ppid = ppid
        self.execPath = execPath
        self.scriptPath = scriptPath
        self.cwd = cwd
        self.footprint = footprint
        self.startTime = startTime
    }

    /// What this process is, for humans: the script it runs when it is an
    /// interpreter, else the binary name.
    public var commandLabel: String {
        if let scriptPath, !scriptPath.isEmpty {
            return (scriptPath as NSString).lastPathComponent
        }
        return executableBasename
    }

    public var identity: ProcessIdentity { ProcessIdentity(pid: pid, start: startTime) }

    public var executableBasename: String {
        (execPath as NSString).lastPathComponent
    }
}

/// Stable process identity across samples: pid alone can be reused by the
/// kernel, but a reused pid starts at a different time.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let start: Double

    public init(pid: Int32, start: Double) {
        self.pid = pid
        self.start = start
    }
}
