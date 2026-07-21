import Foundation

/// One source of truth for byte formatting, binary-based to match how the
/// per-process numbers are read against Activity Monitor.
public func formatBytes(_ bytes: UInt64) -> String {
    let gib = Double(bytes) / 1_073_741_824
    if gib >= 1.0 {
        return String(format: "%.1f GB", gib)
    }
    let mib = Double(bytes) / 1_048_576
    if mib >= 1.0 {
        return String(format: "%.0f MB", mib)
    }
    if bytes >= 1024 {
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
    return "\(bytes) B"
}

public func formatPercent(_ fraction: Double) -> String {
    String(format: "%.0f%%", fraction * 100)
}
