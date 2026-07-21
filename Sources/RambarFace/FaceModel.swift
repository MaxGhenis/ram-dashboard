import Foundation
import SwiftUI
import UserNotifications
import RambarKit
import RambarSystem

/// The face's entire data layer: a periodic read of the store. It owns no
/// collection state — the class of bug where UI timers drive sampling (and
/// end up running against orphaned view models) cannot exist here.
@MainActor
final class FaceModel: ObservableObject {
    @Published var system: SystemRecord?
    @Published var sessions: [SessionRecord] = []
    @Published var history: [SystemRecord] = []
    @Published var orphans: Store.OrphanState?
    @Published var rising: Set<String> = []
    @Published var collectorRunning = false
    @Published var sampledAgo: Double = .infinity

    /// Children shown when a session row expands, sampled on demand.
    @Published var expandedKey: String?
    @Published var expandedChildren: [ProcessSample] = []

    private var store: Store?
    private var timer: Timer?
    private var lastNotifiedEventTs: Double
    private let notificationsAvailable: Bool

    init() {
        lastNotifiedEventTs = UserDefaults.standard.double(forKey: "lastNotifiedEventTs")
        if lastNotifiedEventTs == 0 {
            lastNotifiedEventTs = Date().timeIntervalSince1970
        }
        // UNUserNotificationCenter aborts in unbundled binaries (swift run);
        // notifications only make sense from the installed app anyway.
        notificationsAvailable = Bundle.main.bundleIdentifier != nil

        if notificationsAvailable {
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            ) { _, _ in }
        }
    }

    func start(interval: TimeInterval = 5) {
        refresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        if store == nil {
            store = try? Store(path: Store.defaultPath())
        }
        guard let store else {
            collectorRunning = false
            return
        }

        let now = Date().timeIntervalSince1970
        let latest = store.latestSystem()
        sampledAgo = latest.map { now - $0.ts } ?? .infinity
        collectorRunning = sampledAgo <= 20

        guard collectorRunning else {
            // Show whatever the store last knew, clearly marked stale by the footer.
            system = latest
            sessions = store.activeSessions(now: latest?.ts ?? now)
            history = store.systemHistory(since: now - 3_600)
            orphans = store.latestOrphanState()
            return
        }

        system = latest
        sessions = store.activeSessions(now: now)
        history = store.systemHistory(since: now - 3_600)
        orphans = store.latestOrphanState()

        var nowRising: Set<String> = []
        for session in sessions {
            let points = store.sessionHistory(key: session.key, since: now - 600)
            if isRising(slopeBytesPerSecond: footprintSlope(points)) {
                nowRising.insert(session.key)
            }
        }
        rising = nowRising

        notifyNewEvents(store: store)
    }

    // MARK: - Expansion

    func toggleExpansion(_ session: SessionRecord) {
        if expandedKey == session.key {
            expandedKey = nil
            expandedChildren = []
            return
        }
        expandedKey = session.key
        // One user-initiated live sample; the panel is otherwise store-only.
        let trees = buildSessionTrees(collectProcessSamples())
        let children = trees.first { $0.key == session.key }?.children ?? []
        expandedChildren = Array(children.sorted { $0.footprint > $1.footprint }.prefix(6))
    }

    // MARK: - Orphan reclaim

    func reclaimOrphans() {
        guard let orphans else { return }
        for pid in orphans.pids {
            kill(pid, SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Notifications

    private func notifyNewEvents(store: Store) {
        guard notificationsAvailable else { return }
        let events = store.events(since: lastNotifiedEventTs)
        guard !events.isEmpty else { return }
        lastNotifiedEventTs = events.last!.ts
        UserDefaults.standard.set(lastNotifiedEventTs, forKey: "lastNotifiedEventTs")

        for event in events {
            let payload = (try? JSONSerialization.jsonObject(
                with: Data(event.payload.utf8)
            )) as? [String: String] ?? [:]

            let content = UNMutableNotificationContent()
            switch event.kind {
            case EventKind.pressure where payload["to"] != "normal":
                content.title = "Memory pressure \(payload["to"] ?? "")"
                if let project = payload["mover_project"],
                   let delta = payload["mover_delta"].flatMap(UInt64.init) {
                    content.body = "Biggest recent mover: \(project), +\(formatBytes(delta)) in 10 min"
                } else {
                    content.body = "The kernel raised memory pressure"
                }
            case EventKind.orphans:
                let count = payload["count"] ?? "?"
                let footprint = payload["footprint"].flatMap(UInt64.init).map(formatBytes) ?? ""
                content.title = "Agent helpers left behind"
                content.body = "\(count) processes outlived their session, using \(footprint)"
            case EventKind.attention:
                let project = payload["project"] ?? "session"
                let footprint = payload["footprint"].flatMap(UInt64.init).map(formatBytes) ?? ""
                content.title = "Session running large"
                content.body = "\(project) is at \(footprint) (\(payload["procs"] ?? "?") processes)"
            default:
                continue
            }
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "rambar-\(event.kind)-\(Int(event.ts))",
                content: content,
                trigger: nil
            ))
        }
    }

    // MARK: - Derived display values

    var usedPercentText: String {
        guard let system, system.total > 0 else { return "–" }
        return formatPercent(Double(system.used) / Double(system.total))
    }

    var pressure: PressureLevel { system?.pressure ?? .normal }

    var attributedTotal: UInt64 { sessions.reduce(0) { $0 + $1.footprint } }

    var familyGroups: [(family: AgentFamily, sessions: [SessionRecord])] {
        AgentFamily.allCases.compactMap { family in
            let members = sessions.filter { $0.family == family }
            return members.isEmpty ? nil : (family, members)
        }
    }
}

extension PressureLevel {
    var tint: Color {
        switch self {
        case .normal: return .green
        case .warn: return .orange
        case .critical: return .red
        }
    }
}
