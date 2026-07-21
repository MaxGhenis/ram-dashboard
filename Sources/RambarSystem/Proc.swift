import Foundation
import Darwin
import RambarKit

/// Thin wrappers over libproc and sysctl. Every call here was verified against
/// the live system before anything was built on it (2026-07-21 spike): pid
/// listing, ppid + start time, resolved executable path, working directory,
/// physical footprint, and argv.
enum Proc {
    static func allPids() -> [Int32] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimated) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    struct BasicInfo {
        let ppid: Int32
        let startTime: Double
    }

    static func basicInfo(_ pid: Int32) -> BasicInfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return BasicInfo(ppid: Int32(bitPattern: info.pbi_ppid), startTime: start)
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// ri_phys_footprint: the per-process attribution Activity Monitor's
    /// Memory column shows, compressed memory included. Fails (nil) for
    /// other users' processes — agent sessions are the current user's, so
    /// those are the ones that matter and they succeed.
    static func physicalFootprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0, info.ri_phys_footprint > 0 else { return nil }
        return info.ri_phys_footprint
    }

    static func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }  // exec path
        while index < size, buffer[index] == 0 { index += 1 }  // padding

        var arguments: [String] = []
        var start = index
        while index < size, arguments.count < Int(argc) {
            if buffer[index] == 0 {
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                index += 1
                start = index
            } else {
                index += 1
            }
        }
        return arguments
    }
}

private let interpreterBasenames: Set<String> = [
    "node", "bun", "deno", "python", "ruby", "perl",
]

private func isInterpreter(_ basename: String) -> Bool {
    interpreterBasenames.contains(basename) || basename.hasPrefix("python3")
}

/// The script an interpreter is running: first argv entry after the binary
/// that is not a flag. Good enough for labels and dedup keys; never used for
/// engine detection (that is exec-path only).
func scriptPath(fromArguments arguments: [String]) -> String? {
    guard arguments.count > 1 else { return nil }
    for argument in arguments.dropFirst() {
        if argument.hasPrefix("-") { continue }
        if argument.contains("=") && !argument.contains("/") { continue }
        return argument
    }
    return nil
}

/// Collect one full pass over the process table into pure ProcessSamples.
/// argv is fetched only for interpreter binaries (script identification);
/// everything else is four cheap syscalls per pid.
public func collectProcessSamples() -> [ProcessSample] {
    var samples: [ProcessSample] = []
    for pid in Proc.allPids() {
        guard let info = Proc.basicInfo(pid),
              let execPath = Proc.executablePath(pid) else { continue }

        let basename = (execPath.lowercased() as NSString).lastPathComponent
        var script: String?
        if isInterpreter(basename), let arguments = Proc.arguments(pid) {
            script = scriptPath(fromArguments: arguments)
        }

        samples.append(ProcessSample(
            pid: pid,
            ppid: info.ppid,
            execPath: execPath,
            scriptPath: script,
            cwd: Proc.workingDirectory(pid),
            footprint: Proc.physicalFootprint(pid) ?? 0,
            startTime: info.startTime
        ))
    }
    return samples
}
