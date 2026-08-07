import SwiftUI
import RambarKit
import RambarSystem

struct EndSessionConfirmationRequest {
    let session: SessionRecord
    let force: Bool

    init(session: SessionRecord, force: Bool = false) {
        self.session = session
        self.force = force
    }

    func perform(_ action: (SessionRecord, SessionInterventionAction) -> Void) {
        action(session, force ? .forceTerminate : .terminate)
    }
}

/// The popover panel. System typography throughout; numbers set in monospaced
/// digits (telemetry register), labels in text register. Color appears only
/// where it carries a referent: kernel pressure and threshold crossings.
struct PanelView: View {
    @ObservedObject var model: FaceModel
    /// ImageRenderer cannot draw ScrollView content or Menu controls; the
    /// --snapshot path renders a flat, bounded list instead.
    var snapshotMode = false
    @State private var pendingEndRequest: EndSessionConfirmationRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 10)

            Divider()

            listContent

            if hasHygiene {
                Divider()
                hygiene
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 344)
        .confirmationDialog(
            "\(pendingEndRequest?.force == true ? "Force end" : "End") "
                + "\(pendingEndRequest?.session.displayName ?? "session")?",
            isPresented: endConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let request = pendingEndRequest {
                Button(request.force ? "Force end" : "End session", role: .destructive) {
                    request.perform { session, action in
                        model.intervene(session, action: action)
                    }
                    pendingEndRequest = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingEndRequest = nil }
        } message: {
            if pendingEndRequest?.force == true {
                Text("Graceful termination failed. Rambar will send SIGKILL to the verified process tree. The session cannot save or clean up first.")
            } else {
                Text("Rambar will send SIGTERM to the verified process tree. Unsaved work in that session may be lost.")
            }
        }
    }

    private var showsProcessGroups: Bool {
        model.groupByApp && !snapshotMode
    }

    @ViewBuilder
    private var listContent: some View {
        if showsProcessGroups {
            processGroupList
        } else {
            sessionList
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        if model.sessions.isEmpty {
            Text("no active agent sessions")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else if snapshotMode {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(snapshotSessionGroups, id: \.family) { group in
                    familySection(group.family, group.sessions)
                }
                if model.sessions.count > snapshotRowLimit {
                    Text("… and \(model.sessions.count - snapshotRowLimit) more sessions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.familyGroups, id: \.family) { group in
                        familySection(group.family, group.sessions)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            // ScrollView has no intrinsic height and collapses inside a
            // MenuBarExtra window — size it to the content, capped.
            .frame(height: sessionListHeight)
        }
    }

    @ViewBuilder
    private var processGroupList: some View {
        if model.collectorNeedsUpdate {
            VStack(spacing: 5) {
                Text("collector update required")
                    .font(.callout.weight(.medium))
                Text("Run the bundled rambar-cli install-daemon command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if !model.hasProcessGroupSnapshot {
            Text("waiting for process sample")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else if model.processGroups.isEmpty {
            Text("no significant process groups")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.processGroups, id: \.key) { group in
                        processGroupRow(group)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            // ScrollView has no intrinsic height and collapses inside a
            // MenuBarExtra window — size it to the content, capped.
            .frame(height: processGroupListHeight)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let system = model.system {
                    Text(gbNumber(system.used))
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(gbNumber(system.total)) GB")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("waiting for first sample")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                pressureBadge
            }

            SparklineView(
                points: model.history.map { ($0.ts, Double($0.used) / Double(max($0.total, 1))) },
                tint: model.pressure.tint
            )
            .frame(height: 26)

            if let system = model.system {
                Text(headerSummary(for: system))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func headerSummary(for system: SystemRecord) -> String {
        if showsProcessGroups {
            return "compressed \(formatBytes(system.compressed))"
                + " · \(model.processGroups.count) process groups"
        }
        return "compressed \(formatBytes(system.compressed))"
            + " · agents \(formatBytes(model.attributedTotal))"
            + " across \(model.sessions.count) sessions"
    }

    private var pressureBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.pressure.tint)
                .frame(width: 6, height: 6)
            Text(model.pressure.label)
                .font(.caption.weight(.medium))
                .monospaced()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .help("Kernel memory-pressure level — the signal that matters, not the raw percent")
    }

    // MARK: - Sessions and process groups

    private func familySection(_ family: AgentFamily, _ sessions: [SessionRecord]) -> some View {
        let total = sessions.reduce(UInt64(0)) { $0 + $1.footprint }
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(family.displayName.uppercased())
                    .kerning(0.8)
                Spacer()
                Text("\(sessions.count) · \(formatBytes(total))")
                    .monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 3)

            ForEach(sessions, id: \.key) { session in
                sessionRow(session)
            }
        }
    }

    private func processGroupRow(_ group: ProcessGroup) -> some View {
        let expanded = model.expandedGroupKey == group.key
        return VStack(alignment: .leading, spacing: 0) {
            if group.family != nil {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        model.toggleExpansion(group)
                    }
                } label: {
                    processGroupLabel(group, expanded: expanded)
                }
                .buttonStyle(.plain)
            } else {
                processGroupLabel(group, expanded: false)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 1) {
                    if group.hostProcessCount > 0 {
                        hostRow(group)
                    }
                    ForEach(model.sessions(for: group), id: \.key) { session in
                        sessionRow(session)
                    }
                    if model.sessions(for: group).isEmpty {
                        Text("no active session details")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.leading, 10)
            }
        }
    }

    private func hostRow(_ group: ProcessGroup) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("shared background")
                    .font(.system(size: 13, weight: .medium))
                Text("\(group.hostProcessCount) procs outside chat trees")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(formatBytes(group.hostFootprint))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    private func processGroupLabel(_ group: ProcessGroup, expanded: Bool) -> some View {
        HStack(spacing: 8) {
            Text(group.displayName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Text(groupCountLabel(group))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))

            Spacer(minLength: 8)

            Text(formatBytes(group.footprint))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(group.footprint >= sessionFootprintWarningBytes ? .orange : .primary)
                .help("Sum of macOS process footprints; shared memory can appear in more than one row")

            if group.family != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(expanded ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func groupCountLabel(_ group: ProcessGroup) -> String {
        if group.family != nil {
            return group.sessionCount == 1 ? "1 session" : "\(group.sessionCount) sessions"
        }
        return group.processCount == 1 ? "1 proc" : "\(group.processCount) procs"
    }

    private func sessionRow(_ session: SessionRecord) -> some View {
        let expanded = model.expandedKey == session.key
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    model.toggleExpansion(session)
                }
            } label: {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(session.title ?? session.project)
                        Text(subtitle(for: session))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if model.rising.contains(session.key) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .help("Grew ≥ 1 MB/min over the last 10 minutes")
                    }
                    if let state = model.sessionInterventionStates[session.key],
                       state.status != .running {
                        Image(systemName: state.status == .stopped
                            ? "pause.fill"
                            : "pause.circle")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .help(state.status == .stopped
                                ? "This session is paused"
                                : "\(state.stoppedProcessCount) of "
                                    + "\(state.processCount) processes stopped")
                    }
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(formatBytes(session.footprint))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(session.needsAttention ? .orange : .primary)
                        Text("\(session.processCount) procs")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(expanded ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    sessionControls(session)
                    if let id = session.sessionID {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("session ID")
                                .foregroundStyle(.tertiary)
                            Text(id)
                                .monospaced()
                                .textSelection(.enabled)
                        }
                        .font(.caption2)
                    }
                    Text("largest processes")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                    ForEach(model.expandedProcesses, id: \.pid) { process in
                        HStack {
                            Text(process.commandLabel)
                                .lineLimit(1)
                            Spacer()
                            Text(formatBytes(process.footprint))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if model.expandedProcesses.isEmpty {
                        Text("no live process details")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
            }
        }
    }

    private func sessionControls(_ session: SessionRecord) -> some View {
        let busy = model.interveningKeys.contains(session.key)
        let forceEndRequired = model.forceEndRequiredKeys.contains(session.key)
        let state = model.sessionInterventionStates[session.key]
            ?? SessionTreeInterventionState(
                stoppedProcessCount: 0,
                runningProcessCount: max(session.processCount, 0)
            )
        let title: String
        let symbol: String
        switch state.status {
        case .running:
            title = "Session controls"
            symbol = "switch.2"
        case .partiallyStopped:
            title = "Session partially paused"
            symbol = "pause.circle"
        case .stopped:
            title = "Session paused"
            symbol = "pause.circle.fill"
        }

        let interruptButton = Button {
            model.intervene(session, action: .interrupt)
        } label: {
            Label("Interrupt", systemImage: "stop.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .help("Send SIGINT to the agent root, like pressing Control-C")

        let pauseButton = Button {
            model.intervene(session, action: .pause)
        } label: {
            Label("Pause", systemImage: "pause.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .help(state.status == .partiallyStopped
            ? "Retry pausing this session's verified process tree"
            : "Pause this session's verified process tree")

        let resumeButton = Button {
            model.intervene(session, action: .resume)
        } label: {
            Label("Resume", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.green)
        .help("Resume this session's verified process tree")

        let primaryResumeButton = Button {
            model.intervene(session, action: .resume)
        } label: {
            Label("Resume", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .help("Resume this session's verified process tree")

        let endButton = Button {
            pendingEndRequest = EndSessionConfirmationRequest(
                session: session,
                force: forceEndRequired
            )
        } label: {
            Label(forceEndRequired ? "Force End" : "End", systemImage: "power")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .help(forceEndRequired
            ? "Force the verified process tree to exit after graceful termination failed"
            : "Ask this session's verified process tree to terminate")

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(
                    state.status == .running ? Color.secondary : Color.orange
                )
                Spacer()
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if state.status == .partiallyStopped {
                Text("\(state.stoppedProcessCount) of \(state.processCount) processes stopped")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Group {
                if state.status == .partiallyStopped {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            pauseButton
                            resumeButton
                        }
                        HStack(spacing: 6) {
                            interruptButton
                            endButton
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        interruptButton
                        if state.status == .stopped {
                            primaryResumeButton
                        } else {
                            pauseButton
                        }
                        endButton
                    }
                }
            }
            .font(.caption.weight(.medium))
            .controlSize(.small)
            .disabled(busy)

            if let message = model.interventionMessages[session.key] {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private func subtitle(for session: SessionRecord) -> String {
        var parts: [String] = []
        // When the title leads, the project still earns its place below —
        // unless it is just "~", which says nothing.
        if session.title != nil, session.project != "~" {
            parts.append(session.project)
        }
        parts.append(session.mode.label)
        if let id = session.sessionID {
            parts.append(String(id.prefix(8)))
        } else {
            parts.append("pid \(session.rootPid)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Hygiene

    private var hasHygiene: Bool {
        (model.orphans?.count ?? 0) > 0 || !(model.orphans?.duplicates.isEmpty ?? true)
    }

    @State private var confirmingReclaim = false

    private var hygiene: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let orphans = model.orphans, orphans.count > 0 {
                HStack {
                    Label {
                        Text("\(orphans.count) helpers outlived their session · \(formatBytes(orphans.footprint))")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "moon.zzz")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    Spacer()
                    Button("Reclaim") { confirmingReclaim = true }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .disabled(!model.canReclaimOrphans)
                        .confirmationDialog(
                            "Send SIGTERM to \(orphans.count) orphaned helper processes?",
                            isPresented: $confirmingReclaim
                        ) {
                            Button("Terminate helpers", role: .destructive) {
                                model.reclaimOrphans()
                            }
                        }
                }
            }
            if let dups = model.orphans?.duplicates, !dups.isEmpty {
                let named = dups.filter {
                    !$0.basename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                ForEach(Array(named.prefix(3)), id: \.stableKey) { dup in
                    Label {
                        Text("\(dup.basename) ×\(dup.count) · \(formatBytes(dup.footprint))")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("The same helper is resident \(dup.count) times across sessions")
                }
                if named.count > 3 {
                    Text("… and \(named.count - 3) more duplicate helper groups")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Footer

    private var pausedSessionFooterText: String? {
        let states = model.sessionInterventionStates.values
        let stopped = states.filter { $0.status == .stopped }.count
        let partial = states.filter { $0.status == .partiallyStopped }.count
        if partial == 0 {
            if stopped == 0 { return nil }
            return stopped == 1 ? "1 session paused" : "\(stopped) sessions paused"
        }
        if stopped == 0 {
            return partial == 1
                ? "1 session partially paused"
                : "\(partial) sessions partially paused"
        }
        return "\(stopped + partial) sessions paused or partially paused"
    }

    private var footer: some View {
        HStack {
            if let settingsError = model.settingsError {
                Label(settingsError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if showsProcessGroups && model.collectorNeedsUpdate {
                Label("collector update required", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let pausedSessionFooterText {
                Label(
                    pausedSessionFooterText,
                    systemImage: "pause.circle.fill"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            } else if model.collectorRunning {
                Text("sampled \(Int(max(model.sampledAgo, 0)))s ago")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            } else {
                Label("collector not running — rambar install-daemon", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if !snapshotMode {
                Menu {
                    Button("Refresh now") { model.refresh() }
                    Divider()
                    Toggle("Notifications", isOn: Binding(
                        get: { model.notificationsEnabled },
                        set: { model.setNotificationsEnabled($0) }
                    ))
                    Toggle("Group by app", isOn: Binding(
                        get: { model.groupByApp },
                        set: { model.setGroupByApp($0) }
                    ))
                    Toggle(
                        "Auto-pause runaway sessions",
                        isOn: Binding(
                            get: { model.autoPauseEnabled },
                            set: { model.setAutoPauseEnabled($0) }
                        )
                    )
                    .help("Opt in to pausing a verified agent tree after two runaway samples. Rambar never ends it automatically.")
                    Divider()
                    Button("Quit Rambar") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var sessionListHeight: CGFloat {
        let rows = CGFloat(model.sessions.count) * 38
        let headers = CGFloat(model.familyGroups.count) * 27
        let expansion = model.expandedKey == nil
            ? 0
            : CGFloat(max(model.expandedProcesses.count, 1)) * 20 + 10
        return min(rows + headers + expansion + 16, 380)
    }

    private var processGroupListHeight: CGFloat {
        let rows = CGFloat(model.processGroups.count) * 38
        let expandedSessions = model.processGroups.first { $0.key == model.expandedGroupKey }
            .map { model.sessions(for: $0).count } ?? 0
        let sessionRows = CGFloat(expandedSessions) * 38
        let expandedHostCount = model.processGroups.first { $0.key == model.expandedGroupKey }?
            .hostProcessCount ?? 0
        let hostRows: CGFloat = expandedHostCount > 0 ? 38 : 0
        let processRows = model.expandedKey == nil
            ? 0
            : CGFloat(max(model.expandedProcesses.count, 1)) * 20 + 42
        return min(rows + sessionRows + hostRows + processRows + 16, 420)
    }

    private var endConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingEndRequest != nil },
            set: { if !$0 { pendingEndRequest = nil } }
        )
    }

    private let snapshotRowLimit = 12

    private var snapshotSessionGroups: [(family: AgentFamily, sessions: [SessionRecord])] {
        var remaining = snapshotRowLimit
        var groups: [(AgentFamily, [SessionRecord])] = []
        for group in model.familyGroups where remaining > 0 {
            let take = Array(group.sessions.prefix(remaining))
            remaining -= take.count
            groups.append((group.family, take))
        }
        return groups
    }

    private func gbNumber(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}
