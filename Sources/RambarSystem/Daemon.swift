import Foundation
import RambarKit

/// Event kinds the daemon records. The face turns some of these into
/// notifications; everything is also queryable via `rambar events`.
public enum EventKind {
    public static let pressure = "pressure"
    public static let orphans = "orphans"
    public static let sessionStarted = "session_started"
    public static let sessionEnded = "session_ended"
    public static let attention = "attention"
}

/// The 5-second sampling loop. Single-threaded over its own store connection;
/// pressure events arrive on the same queue so there is no shared state to
/// lock. This is the only process that writes.
public final class Daemon {
    private let store: Store
    private let home: String
    private let index: SessionIndex
    private let queue = DispatchQueue(label: "org.rambar.daemon")
    private let interval: TimeInterval

    private var tracker = OrphanTracker()
    private var timer: DispatchSourceTimer?
    private var pressureWatcher: PressureWatcher?
    private var lastPressure: PressureLevel = .normal
    private var knownSessionKeys: Set<String> = []
    private var attentionKeys: Set<String> = []
    private var ticksSinceCompaction = 0
    private var lastSystem: SystemMemorySnapshot?

    public init(store: Store, home: String = NSHomeDirectory(), interval: TimeInterval = 5) {
        self.store = store
        self.home = home
        self.index = SessionIndex(home: home)
        self.interval = interval
    }

    /// Runs forever. SIGTERM/SIGINT exit cleanly via signal sources.
    public func run() -> Never {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        for source in [sigterm, sigint] {
            source.setEventHandler { exit(0) }
            source.activate()
        }

        pressureWatcher = PressureWatcher(queue: queue) { [weak self] level in
            self?.notePressure(level, viaEvent: true)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.activate()
        self.timer = timer

        dispatchMain()
    }

    /// One sampling pass, exposed for tests and `rambar collect --once`.
    public func tick() {
        let now = Date().timeIntervalSince1970
        let samples = collectProcessSamples()
        let trees = buildSessionTrees(samples)
        let orphanReport = tracker.update(samples: samples, trees: trees)

        var sessionIDs: [String: String] = [:]
        let unambiguous = keysWithUnambiguousCwd(trees)
        for tree in trees where unambiguous.contains(tree.key) {
            if let id = index.sessionID(
                family: tree.family, cwd: tree.root.cwd, rootStart: tree.root.startTime
            ) {
                sessionIDs[tree.key] = id
            }
        }

        do {
            try store.record(ts: now, trees: trees, sessionIDs: sessionIDs, home: home)
            try store.recordOrphanState(
                ts: now, report: orphanReport, duplicates: findDuplicates(in: trees)
            )
            if let system = collectSystemMemory() {
                lastSystem = system
                try store.record(ts: now, system: system)
                notePressure(system.pressure, viaEvent: false)
            }

            let currentKeys = Set(trees.map(\.key))
            for tree in trees where !knownSessionKeys.contains(tree.key) {
                try store.recordEvent(
                    ts: now,
                    kind: EventKind.sessionStarted,
                    payload: jsonObject([
                        "key": tree.key,
                        "project": tree.projectName(home: home),
                        "family": tree.family.rawValue,
                    ])
                )
            }
            if !knownSessionKeys.isEmpty {
                for key in knownSessionKeys.subtracting(currentKeys) {
                    try store.recordEvent(
                        ts: now, kind: EventKind.sessionEnded,
                        payload: jsonObject(["key": key])
                    )
                }
            }
            knownSessionKeys = currentKeys

            // Sessions crossing the attention thresholds alert once per crossing.
            let currentAttention = Set(
                trees.filter {
                    sessionNeedsAttention(footprint: $0.footprint, processCount: $0.processCount)
                }.map(\.key)
            )
            for tree in trees where currentAttention.contains(tree.key)
                && !attentionKeys.contains(tree.key) {
                try store.recordEvent(
                    ts: now, kind: EventKind.attention,
                    payload: jsonObject([
                        "key": tree.key,
                        "project": tree.projectName(home: home),
                        "footprint": "\(tree.footprint)",
                        "procs": "\(tree.processCount)",
                    ])
                )
            }
            attentionKeys = currentAttention

            if orphanReport.newlyDetected > 0 {
                try store.recordEvent(
                    ts: now, kind: EventKind.orphans,
                    payload: jsonObject([
                        "count": "\(orphanReport.count)",
                        "footprint": "\(orphanReport.footprint)",
                        "pids": orphanReport.identities.map { String($0.pid) }
                            .sorted().joined(separator: ","),
                    ])
                )
            }

            ticksSinceCompaction += 1
            if ticksSinceCompaction >= Int(3600 / max(interval, 1)) {
                ticksSinceCompaction = 0
                try store.compact(now: now)
            }
        } catch {
            FileHandle.standardError.write(Data("rambar daemon: \(error)\n".utf8))
        }
    }

    private func notePressure(_ level: PressureLevel, viaEvent: Bool) {
        guard level != lastPressure else { return }
        let previous = lastPressure
        lastPressure = level
        let now = Date().timeIntervalSince1970

        // Attach the biggest recent mover so the alert names a culprit, not a level.
        var payload = [
            "from": previous.label,
            "to": level.label,
            "push": viaEvent ? "kernel" : "poll",
        ]
        if level.rawValue > previous.rawValue,
           let mover = biggestRecentMover(now: now) {
            payload["mover_project"] = mover.project
            payload["mover_delta"] = "\(mover.delta)"
        }
        try? store.recordEvent(ts: now, kind: EventKind.pressure, payload: jsonObject(payload))
    }

    /// The session whose footprint grew most over the last 10 minutes.
    private func biggestRecentMover(now: Double) -> (project: String, delta: Int64)? {
        var best: (project: String, delta: Int64)?
        for session in store.activeSessions(now: now, staleAfter: 30) {
            let history = store.sessionHistory(key: session.key, since: now - 600)
            guard let first = history.first, let last = history.last else { continue }
            let delta = Int64(bitPattern: last.bytes) - Int64(bitPattern: first.bytes)
            if delta > 0, delta > (best?.delta ?? 0) {
                best = (session.project, delta)
            }
        }
        return best
    }
}

func jsonObject(_ dictionary: [String: String]) -> String {
    let data = (try? JSONSerialization.data(
        withJSONObject: dictionary, options: [.sortedKeys]
    )) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}
