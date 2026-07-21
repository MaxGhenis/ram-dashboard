import Foundation
import Darwin

public enum PressureLevel: Int, Codable, Sendable {
    // Scale shared with dispatch/source.h: NORMAL=0x1, WARN=0x2, CRITICAL=0x4.
    // normal=1 additionally confirmed live via kern.memorystatus_vm_pressure_level.
    case normal = 1
    case warn = 2
    case critical = 4

    public var label: String {
        switch self {
        case .normal: return "normal"
        case .warn: return "warn"
        case .critical: return "critical"
        }
    }
}

public struct SystemMemorySnapshot: Sendable {
    public let total: UInt64
    /// total minus free, file-backed, and purgeable pages — the "memory used"
    /// notion that excludes reclaimable cache.
    public let used: UInt64
    public let free: UInt64
    public let compressed: UInt64
    public let pressure: PressureLevel

    public var usedFraction: Double {
        total == 0 ? 0 : Double(used) / Double(total)
    }
}

public func collectSystemMemory() -> SystemMemorySnapshot? {
    var total: UInt64 = 0
    var totalSize = MemoryLayout<UInt64>.size
    guard sysctlbyname("hw.memsize", &total, &totalSize, nil, 0) == 0 else { return nil }

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }

    let page = UInt64(vm_kernel_page_size)
    let free = UInt64(stats.free_count) * page
    let fileBacked = UInt64(stats.external_page_count) * page
    let purgeable = UInt64(stats.purgeable_count) * page
    let compressed = UInt64(stats.compressor_page_count) * page
    let reclaimable = free + fileBacked + purgeable
    let used = total > reclaimable ? total - reclaimable : 0

    var level: Int32 = 1
    var levelSize = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

    return SystemMemorySnapshot(
        total: total,
        used: used,
        free: free,
        compressed: compressed,
        pressure: PressureLevel(rawValue: Int(level)) ?? .warn
    )
}

/// Push channel for pressure transitions: fires between polls so a spike is
/// recorded the moment the kernel raises it.
public final class PressureWatcher {
    private let source: DispatchSourceMemoryPressure

    public init(queue: DispatchQueue, handler: @escaping (PressureLevel) -> Void) {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak source] in
            guard let data = source?.data else { return }
            if data.contains(.critical) {
                handler(.critical)
            } else if data.contains(.warning) {
                handler(.warn)
            } else {
                handler(.normal)
            }
        }
        source.activate()
    }

    deinit {
        source.cancel()
    }
}
