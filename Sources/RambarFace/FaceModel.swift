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
    @Published var processGroups: [ProcessGroup] = []
    @Published var sessions: [SessionRecord] = []
    @Published var history: [SystemRecord] = []
    @Published var orphans: Store.OrphanState?
    @Published var rising: Set<String> = []
    @Published var collectorRunning = false
    @Published var hasProcessGroupSnapshot = false
    @Published var collectorNeedsUpdate = false
    @Published var sampledAgo: Double = .infinity
    @Published var notificationsEnabled: Bool
    @Published var groupByApp: Bool
    @Published var sessionInterventionStates: [String: SessionTreeInterventionState] = [:]
    @Published var interventionMessages: [String: String] = [:]
    @Published var interveningKeys: Set<String> = []
    @Published var forceEndRequiredKeys: Set<String> = []
    @Published var autoPauseEnabled: Bool
    @Published var settingsError: String?

    /// Processes shown when a session row expands, sampled on demand.
    @Published var expandedGroupKey: String?
    @Published var expandedKey: String?
    @Published var expandedProcesses: [ProcessSample] = []

    private var store: Store?
    private var timer: Timer?
    private var lastNotifiedEventTs: Double
    private let notificationsAvailable: Bool
    private let reclaimFreshnessWindow: Double = 20
    private let defaults: UserDefaults
    private let runawayGuardSettingsPath: String

    private static let notificationsEnabledKey = "notificationsEnabled"
    private static let groupByAppKey = "groupByApp"

    init(
        defaults: UserDefaults = .standard,
        runawayGuardSettingsPath: String = RunawayGuardSettings.defaultPath()
    ) {
        self.defaults = defaults
        self.runawayGuardSettingsPath = runawayGuardSettingsPath
        notificationsEnabled = defaults.object(
            forKey: Self.notificationsEnabledKey
        ) as? Bool ?? false
        groupByApp = defaults.object(
            forKey: Self.groupByAppKey
        ) as? Bool ?? false
        autoPauseEnabled = RunawayGuardSettings.load(
            from: runawayGuardSettingsPath
        ).autoPauseEnabled
        lastNotifiedEventTs = defaults.double(forKey: "lastNotifiedEventTs")
        if lastNotifiedEventTs == 0 {
            lastNotifiedEventTs = Date().timeIntervalSince1970
        }
        // UNUserNotificationCenter aborts in unbundled binaries (swift run);
        // notifications only make sense from the installed app anyway.
        notificationsAvailable = Bundle.main.bundleIdentifier != nil

        if notificationsAvailable && notificationsEnabled {
            requestNotificationAuthorization()
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
        let processGroupStatus = store.processGroupSnapshotStatus(now: now)
        sampledAgo = latest.map { now - $0.ts } ?? .infinity
        collectorRunning = sampledAgo <= 20
        hasProcessGroupSnapshot = processGroupStatus != .missing
        collectorNeedsUpdate = collectorRunning && processGroupStatus != .fresh

        guard collectorRunning else {
            // Show whatever the store last knew, clearly marked stale by the footer.
            system = latest
            processGroups = store.activeProcessGroups(now: latest?.ts ?? now)
            sessions = store.activeSessions(now: latest?.ts ?? now)
            history = store.systemHistory(since: now - 3_600)
            orphans = store.latestOrphanState()
            reconcileExpansion()
            refreshSessionInterventionStates()
            return
        }

        system = latest
        processGroups = store.activeProcessGroups(now: now)
        sessions = store.activeSessions(now: now)
        history = store.systemHistory(since: now - 3_600)
        orphans = store.latestOrphanState()
        reconcileExpansion()
        refreshSessionInterventionStates()

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

    private func reconcileExpansion() {
        let activeKeys = Set(sessions.map(\.key))
        interventionMessages = interventionMessages.filter {
            activeKeys.contains($0.key)
        }
        forceEndRequiredKeys.formIntersection(activeKeys)
        if let expandedGroupKey,
           !processGroups.contains(where: { $0.key == expandedGroupKey }) {
            self.expandedGroupKey = nil
            expandedKey = nil
            expandedProcesses = []
        } else if let expandedKey,
                  !sessions.contains(where: { $0.key == expandedKey }) {
            self.expandedKey = nil
            expandedProcesses = []
        }
    }

    func toggleExpansion(_ group: ProcessGroup) {
        guard group.family != nil else { return }
        if expandedGroupKey == group.key {
            expandedGroupKey = nil
            expandedKey = nil
            expandedProcesses = []
        } else {
            expandedGroupKey = group.key
            expandedKey = nil
            expandedProcesses = []
        }
    }

    func toggleExpansion(_ session: SessionRecord) {
        if expandedKey == session.key {
            expandedKey = nil
            expandedProcesses = []
            return
        }
        expandedKey = session.key
        // One user-initiated live sample; the panel is otherwise store-only.
        let trees = buildSessionTrees(collectProcessSamples())
        let processes = trees.first { $0.key == session.key }?.members ?? []
        expandedProcesses = Array(
            processes.sorted { $0.footprint > $1.footprint }.prefix(6)
        )
    }

    // MARK: - Runaway containment

    func setAutoPauseEnabled(_ enabled: Bool) {
        do {
            try RunawayGuardSettings(autoPauseEnabled: enabled)
                .save(to: runawayGuardSettingsPath)
            autoPauseEnabled = enabled
            settingsError = nil
        } catch {
            settingsError = "Could not save auto-pause setting"
        }
    }

    func intervene(_ session: SessionRecord, action: SessionInterventionAction) {
        guard interveningKeys.insert(session.key).inserted else { return }
        interventionMessages.removeValue(forKey: session.key)
        let root = ProcessIdentity(pid: session.rootPid, start: session.rootStart)
        let key = session.key

        Task.detached(priority: .userInitiated) {
            let result = performSessionIntervention(root: root, action: action)
            // Signal delivery is not the outcome. In particular, a terminal
            // can immediately stop a continued background job again, and a
            // stopped process can keep SIGTERM pending indefinitely.
            await waitForSessionInterventionSettlement(root: root, action: action)
            let observedTree = buildSessionTrees(collectProcessSamples())
                .first { $0.root.identity == root }
            let observedState = observedTree.map(sessionTreeInterventionState)
            let terminalForegroundMismatch = processTerminalState(root)?
                .isInBackgroundProcessGroup ?? false
            await MainActor.run { [weak self] in
                self?.finishIntervention(
                    result,
                    action: action,
                    key: key,
                    observedState: observedState,
                    terminalForegroundMismatch: terminalForegroundMismatch
                )
            }
        }
    }

    private func finishIntervention(
        _ result: SessionInterventionResult,
        action: SessionInterventionAction,
        key: String,
        observedState: SessionTreeInterventionState?,
        terminalForegroundMismatch: Bool
    ) {
        interveningKeys.remove(key)
        if let observedState {
            sessionInterventionStates[key] = observedState
        } else {
            sessionInterventionStates.removeValue(forKey: key)
        }

        let feedback = interventionFeedback(
            result: result,
            action: action,
            observedState: observedState,
            terminalForegroundMismatch: terminalForegroundMismatch
        )
        interventionMessages[key] = feedback.message
        if action == .terminate || action == .forceTerminate {
            if feedback.requiresForceEnd {
                forceEndRequiredKeys.insert(key)
            } else {
                forceEndRequiredKeys.remove(key)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.refresh()
        }
    }

    private func refreshSessionInterventionStates() {
        let activeKeys = Set(sessions.map(\.key))
        sessionInterventionStates = buildSessionTrees(collectProcessSamples())
            .reduce(into: [:]) { result, tree in
                guard activeKeys.contains(tree.key) else { return }
                result[tree.key] = sessionTreeInterventionState(tree)
            }
    }

    // MARK: - Orphan reclaim

    var canReclaimOrphans: Bool {
        guard collectorRunning, let orphans, orphans.count > 0 else { return false }
        return orphans.isFresh(
            now: Date().timeIntervalSince1970,
            maxAge: reclaimFreshnessWindow
        )
    }

    func reclaimOrphans() {
        guard canReclaimOrphans, let orphans else { return }
        let samples = collectProcessSamples()
        let reclaimable = reclaimableOrphanIdentities(
            recorded: Set(orphans.identities),
            samples: samples,
            trees: buildSessionTrees(samples)
        )
        for identity in reclaimable {
            kill(identity.pid, SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Notifications

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        defaults.set(enabled, forKey: Self.notificationsEnabledKey)
        guard notificationsAvailable else { return }
        if enabled {
            requestNotificationAuthorization()
        } else {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        }
    }

    func setGroupByApp(_ enabled: Bool) {
        groupByApp = enabled
        defaults.set(enabled, forKey: Self.groupByAppKey)
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    private func notifyNewEvents(store: Store) {
        let events = store.events(since: lastNotifiedEventTs)
        guard !events.isEmpty else { return }
        let batch = notificationBatch(
            events: events,
            enabled: notificationsAvailable && notificationsEnabled
        )
        if let updatedThrough = batch.updatedThrough {
            lastNotifiedEventTs = updatedThrough
            defaults.set(updatedThrough, forKey: "lastNotifiedEventTs")
        }

        for message in batch.messages {
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: message.identifier,
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

    var pausedSessionKeys: Set<String> {
        Set(sessionInterventionStates.compactMap { key, state in
            state.status == .running ? nil : key
        })
    }

    var menuBarSymbolName: String {
        if !pausedSessionKeys.isEmpty { return "pause.circle.fill" }
        return pressure == .normal ? "memorychip" : "memorychip.fill"
    }

    var familyGroups: [(family: AgentFamily, sessions: [SessionRecord])] {
        AgentFamily.allCases.compactMap { family in
            let members = sessions.filter { $0.family == family }
            return members.isEmpty ? nil : (family, members)
        }
    }

    func sessions(for group: ProcessGroup) -> [SessionRecord] {
        guard let family = group.family else { return [] }
        return sessions.filter { $0.family == family }
    }
}

struct InterventionFeedback: Equatable {
    let message: String
    let requiresForceEnd: Bool
}

func interventionFeedback(
    result: SessionInterventionResult,
    action: SessionInterventionAction,
    observedState: SessionTreeInterventionState?,
    terminalForegroundMismatch: Bool
) -> InterventionFeedback {
    guard result.foundSession else {
        return InterventionFeedback(
            message: "Session ended before it could be signaled.",
            requiresForceEnd: false
        )
    }

    if observedState == nil {
        switch action {
        case .terminate:
            return InterventionFeedback(message: "Session ended.", requiresForceEnd: false)
        case .forceTerminate:
            return InterventionFeedback(
                message: "Session force ended.",
                requiresForceEnd: false
            )
        default:
            break
        }
    }

    guard result.completedAllTargets else {
        let label: String
        switch action {
        case .interrupt: label = "Interrupt incomplete"
        case .pause: label = "Pause incomplete"
        case .resume: label = "Resume incomplete"
        case .terminate: label = "End request incomplete"
        case .forceTerminate: label = "Force End incomplete"
        }
        return InterventionFeedback(
            message: "\(label): "
                + "\(result.signaledProcessCount) of \(result.targetedProcessCount) signaled"
                + " · \(result.failedProcessCount) failed"
                + " · \(result.staleProcessCount) stale"
                + " · \(result.missedProcessCount) missed.",
            requiresForceEnd: (action == .terminate || action == .forceTerminate)
                && observedState != nil
        )
    }

    let noun = result.signaledProcessCount == 1 ? "process" : "processes"
    switch action {
    case .interrupt:
        return InterventionFeedback(
            message: "Interrupt sent to \(result.signaledProcessCount) \(noun).",
            requiresForceEnd: false
        )
    case .pause:
        guard let observedState else {
            return InterventionFeedback(message: "Session ended.", requiresForceEnd: false)
        }
        guard observedState.status != .running else {
            return InterventionFeedback(
                message: "Pause did not take effect.",
                requiresForceEnd: false
            )
        }
        return InterventionFeedback(
            message: "Paused \(observedState.stoppedProcessCount) of "
                + "\(observedState.processCount) processes.",
            requiresForceEnd: false
        )
    case .resume:
        guard let observedState else {
            return InterventionFeedback(
                message: "Session ended while resuming.",
                requiresForceEnd: false
            )
        }
        guard observedState.status == .running else {
            let message = terminalForegroundMismatch
                ? "The terminal reclaimed this job. Open its original terminal and run `fg`."
                : "Resume did not take effect; \(observedState.stoppedProcessCount) processes remain stopped."
            return InterventionFeedback(message: message, requiresForceEnd: false)
        }
        return InterventionFeedback(
            message: "Resumed \(observedState.processCount) processes.",
            requiresForceEnd: false
        )
    case .terminate:
        guard observedState == nil else {
            return InterventionFeedback(
                message: "Session did not end gracefully. Use Force End to stop it immediately.",
                requiresForceEnd: true
            )
        }
        return InterventionFeedback(message: "Session ended.", requiresForceEnd: false)
    case .forceTerminate:
        guard observedState == nil else {
            return InterventionFeedback(
                message: "Force End did not remove the verified process tree.",
                requiresForceEnd: true
            )
        }
        return InterventionFeedback(message: "Session force ended.", requiresForceEnd: false)
    }
}

private func waitForSessionInterventionSettlement(
    root: ProcessIdentity,
    action: SessionInterventionAction,
    timeout: TimeInterval = 2
) async {
    guard action != .interrupt else { return }
    let deadline = Date().addingTimeInterval(timeout)
    var stableSince: Date?

    while Date() < deadline {
        let stopped = processIsStopped(root)
        let reachedExpectedState: Bool
        let requiredStableDuration: TimeInterval
        switch action {
        case .interrupt:
            return
        case .pause:
            reachedExpectedState = stopped == true
            requiredStableDuration = 0.15
        case .resume:
            reachedExpectedState = stopped == false
            requiredStableDuration = 0.3
        case .terminate, .forceTerminate:
            reachedExpectedState = stopped == nil
            requiredStableDuration = 0
        }

        if reachedExpectedState {
            let now = Date()
            if stableSince == nil { stableSince = now }
            if now.timeIntervalSince(stableSince!) >= requiredStableDuration {
                return
            }
        } else {
            stableSince = nil
        }
        try? await Task<Never, Never>.sleep(for: .milliseconds(50))
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
