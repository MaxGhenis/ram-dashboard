import Foundation

/// Processes that were part of an agent session tree and outlived it (or
/// detached from it while the root kept running). MCP servers and dev servers
/// left behind by closed sessions are the classic case.
public struct OrphanReport: Sendable {
    public let identities: Set<ProcessIdentity>
    public let footprint: UInt64
    /// Orphans promoted in this update — notifications key off this so a
    /// standing orphan doesn't re-alert every scan.
    public let newlyDetected: Int

    public var count: Int { identities.count }

    public static let empty = OrphanReport(identities: [], footprint: 0, newlyDetected: 0)
}

/// Detects orphaned helpers across successive scans.
///
/// A process becomes a candidate when it was a session-tree child on the
/// previous scan and is now alive but unclaimed (its session ended, or it
/// reparented away while the root lives). It must survive two further scans
/// before being reported, so short-lived teardown states never alert.
/// Identity is (pid, startTime), which is immune to pid reuse.
public struct OrphanTracker: Sendable {
    private var previousChildren: Set<ProcessIdentity> = []
    private var candidateObservations: [ProcessIdentity: Int] = [:]
    private var orphans: Set<ProcessIdentity> = []

    public init() {}

    public mutating func update(
        samples: [ProcessSample],
        trees: [AgentSessionTree]
    ) -> OrphanReport {
        var footprints: [ProcessIdentity: UInt64] = [:]
        var alive: Set<ProcessIdentity> = []
        for sample in samples where sample.pid > 0 {
            alive.insert(sample.identity)
            footprints[sample.identity] = sample.footprint
        }

        var claimed: Set<ProcessIdentity> = []
        var claimedChildren: Set<ProcessIdentity> = []
        for tree in trees {
            for member in tree.members {
                claimed.insert(member.identity)
                if member.pid != tree.root.pid {
                    claimedChildren.insert(member.identity)
                }
            }
        }

        func stillDetached(_ identity: ProcessIdentity) -> Bool {
            alive.contains(identity) && !claimed.contains(identity)
        }

        orphans = orphans.filter(stillDetached)
        candidateObservations = candidateObservations.filter { stillDetached($0.key) }

        var newlyDetected = 0
        for (identity, observations) in candidateObservations {
            let next = observations + 1
            if next >= 2 {
                orphans.insert(identity)
                candidateObservations.removeValue(forKey: identity)
                newlyDetected += 1
            } else {
                candidateObservations[identity] = next
            }
        }

        for identity in previousChildren
        where !claimedChildren.contains(identity)
            && stillDetached(identity)
            && !orphans.contains(identity)
            && candidateObservations[identity] == nil {
            // Seed at zero: promotion needs two further scans after the
            // detachment scan (~10 s at the default cadence), so teardown
            // helpers that linger a few seconds never alert.
            candidateObservations[identity] = 0
        }

        previousChildren = claimedChildren

        let footprint = orphans.reduce(UInt64(0)) { $0 + (footprints[$1] ?? 0) }
        return OrphanReport(identities: orphans, footprint: footprint, newlyDetected: newlyDetected)
    }
}
