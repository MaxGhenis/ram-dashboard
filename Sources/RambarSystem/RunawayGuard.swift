import Foundation
import RambarKit

public struct RunawayGuardSettings: Codable, Equatable, Sendable {
    public var autoPauseEnabled: Bool

    public init(autoPauseEnabled: Bool = false) {
        self.autoPauseEnabled = autoPauseEnabled
    }

    public static let `default` = RunawayGuardSettings()

    public static func defaultPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".rambar/runaway-guard.json")
    }

    public static func load(from path: String = defaultPath()) -> RunawayGuardSettings {
        guard let data = FileManager.default.contents(atPath: path),
              let settings = try? JSONDecoder().decode(RunawayGuardSettings.self, from: data)
        else { return .default }
        return settings
    }

    public func save(to path: String = defaultPath()) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

public enum RunawayIncidentReason: String, Equatable, Sendable {
    case largeUnderPressure
    case rapidGrowth
}

public struct RunawayIncident: Equatable, Sendable {
    public let sessionKey: String
    public let root: ProcessIdentity
    public let largestProcess: ProcessIdentity
    public let largestProcessFootprint: UInt64
    public let sessionFootprint: UInt64
    public let reason: RunawayIncidentReason
}

/// Stateful policy for the collector's opt-in containment loop. Decisions use
/// the largest single process, not the additive session total, because shared
/// pages can make summed process footprints exceed physical memory.
public struct RunawayGuard: Sendable {
    /// Automatic containment is deliberately reversible. Ending a session is
    /// always a manual, confirmed action in the UI.
    public static let automaticAction = SessionInterventionAction.pause

    private struct Observation: Sendable {
        let ts: Double
        let identity: ProcessIdentity
        let footprint: UInt64
    }

    private var history: [String: [Observation]] = [:]
    private var suspectCounts: [String: Int] = [:]
    private var contained: Set<String> = []

    private let warningFraction = 0.15
    private let pauseFraction = 0.30
    private let rapidGrowthFraction = 0.10
    private let growthWindow: Double = 30
    private let requiredSamples = 2

    public init() {}

    public mutating func evaluate(
        now: Double,
        totalMemory: UInt64,
        pressure: PressureLevel,
        trees: [AgentSessionTree],
        settings: RunawayGuardSettings
    ) -> [RunawayIncident] {
        guard settings.autoPauseEnabled, totalMemory > 0 else {
            history.removeAll()
            suspectCounts.removeAll()
            contained.removeAll()
            return []
        }

        let activeKeys = Set(trees.map(\.key))
        history = history.filter { activeKeys.contains($0.key) }
        suspectCounts = suspectCounts.filter { activeKeys.contains($0.key) }
        contained.formIntersection(activeKeys)

        var incidents: [RunawayIncident] = []
        for tree in trees {
            guard let largest = tree.members.max(by: { $0.footprint < $1.footprint }) else { continue }
            let cutoff = now - growthWindow
            var observations = history[tree.key, default: []].filter { $0.ts >= cutoff }
            observations.append(Observation(
                ts: now,
                identity: largest.identity,
                footprint: largest.footprint
            ))
            history[tree.key] = observations

            let memoryFraction = Double(largest.footprint) / Double(totalMemory)
            if memoryFraction < warningFraction {
                suspectCounts[tree.key] = 0
                contained.remove(tree.key)
                continue
            }

            let baseline = observations.first {
                $0.identity == largest.identity
            }?.footprint ?? largest.footprint
            let growth = largest.footprint > baseline ? largest.footprint - baseline : 0
            let growthFraction = Double(growth) / Double(totalMemory)
            let largeUnderPressure = memoryFraction >= pauseFraction && pressure != .normal
            let rapidGrowth = growthFraction >= rapidGrowthFraction

            guard largeUnderPressure || rapidGrowth else {
                suspectCounts[tree.key] = 0
                continue
            }

            let nextCount = suspectCounts[tree.key, default: 0] + 1
            suspectCounts[tree.key] = nextCount
            guard nextCount >= requiredSamples, !contained.contains(tree.key) else { continue }

            incidents.append(RunawayIncident(
                sessionKey: tree.key,
                root: tree.root.identity,
                largestProcess: largest.identity,
                largestProcessFootprint: largest.footprint,
                sessionFootprint: tree.footprint,
                reason: rapidGrowth ? .rapidGrowth : .largeUnderPressure
            ))
        }
        return incidents
    }

    public mutating func markContained(sessionKey: String) {
        contained.insert(sessionKey)
    }
}

/// Contain the process that actually crossed the runaway threshold. Stopping
/// an entire terminal job lets its shell reclaim the foreground process group,
/// after which SIGCONT alone cannot reliably resume the agent. Keeping an
/// unaffected root running preserves terminal ownership when a helper is the
/// runaway process.
func performRunawayContainment(
    _ incident: RunawayIncident,
    identityLookup: (Int32) -> ProcessIdentity?,
    sendSignal: (Int32, Int32) -> Int32
) -> SessionInterventionResult {
    guard identityLookup(incident.root.pid) == incident.root else {
        return SessionInterventionResult(
            foundSession: false,
            targetedProcessCount: 1,
            signaledProcessCount: 0,
            staleProcessCount: 1,
            failedProcessCount: 0
        )
    }
    guard identityLookup(incident.largestProcess.pid) == incident.largestProcess else {
        return SessionInterventionResult(
            foundSession: true,
            targetedProcessCount: 1,
            signaledProcessCount: 0,
            staleProcessCount: 1,
            failedProcessCount: 0
        )
    }

    let succeeded = sendSignal(incident.largestProcess.pid, SIGSTOP) == 0
    return SessionInterventionResult(
        foundSession: true,
        targetedProcessCount: 1,
        signaledProcessCount: succeeded ? 1 : 0,
        staleProcessCount: 0,
        failedProcessCount: succeeded ? 0 : 1
    )
}
