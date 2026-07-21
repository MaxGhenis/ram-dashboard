import SwiftUI
import RambarKit
import RambarSystem

/// The popover panel. System typography throughout; numbers set in monospaced
/// digits (telemetry register), labels in text register. Color appears only
/// where it carries a referent: kernel pressure and threshold crossings.
struct PanelView: View {
    @ObservedObject var model: FaceModel
    /// ImageRenderer cannot draw ScrollView content or Menu controls; the
    /// --snapshot path renders a flat, bounded list instead.
    var snapshotMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 10)

            Divider()

            if model.sessions.isEmpty {
                Text("no active agent sessions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else if snapshotMode {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(snapshotGroups, id: \.family) { group in
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
                Text("compressed \(formatBytes(system.compressed))"
                    + " · agents \(formatBytes(model.attributedTotal))"
                    + " across \(model.sessions.count) sessions")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
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

    // MARK: - Sessions

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
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.expandedChildren, id: \.pid) { child in
                        HStack {
                            Text(child.commandLabel)
                                .lineLimit(1)
                            Spacer()
                            Text(formatBytes(child.footprint))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if model.expandedChildren.isEmpty {
                        Text("no helper processes")
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
                ForEach(dups, id: \.basename) { dup in
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
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if model.collectorRunning {
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
            : CGFloat(max(model.expandedChildren.count, 1)) * 20 + 10
        return min(rows + headers + expansion + 16, 380)
    }

    private let snapshotRowLimit = 12

    private var snapshotGroups: [(family: AgentFamily, sessions: [SessionRecord])] {
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
