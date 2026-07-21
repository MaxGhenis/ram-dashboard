import Foundation
import RambarKit
import RambarSystem

/// Where a reading came from. The store is authoritative when the daemon is
/// running; live sampling is the fallback so the CLI works before install.
enum SnapshotSource: String {
    case store
    case live
}

let storeFreshnessWindow: Double = 20

func openStore() -> Store? {
    try? Store(path: Store.defaultPath())
}

func storeIsFresh(_ store: Store, now: Double) -> Bool {
    guard let latest = store.latestSystem() else { return false }
    return now - latest.ts <= storeFreshnessWindow
}

/// Active sessions from the freshest source available.
func currentSessions() -> (sessions: [SessionRecord], source: SnapshotSource) {
    let now = Date().timeIntervalSince1970
    if let store = openStore(), storeIsFresh(store, now: now) {
        return (store.activeSessions(now: now), .store)
    }
    return (liveSessions(now: now), .live)
}

func liveSessions(now: Double) -> [SessionRecord] {
    let home = NSHomeDirectory()
    let index = SessionIndex(home: home)
    let trees = buildSessionTrees(collectProcessSamples())
    let unambiguous = keysWithUnambiguousCwd(trees)
    return trees.map { tree in
        var sessionID: String?
        var title: String?
        if unambiguous.contains(tree.key) {
            sessionID = index.sessionID(
                family: tree.family, cwd: tree.root.cwd, rootStart: tree.root.startTime
            )
            if let sessionID {
                title = index.title(family: tree.family, cwd: tree.root.cwd, sessionID: sessionID)
            }
        }
        return SessionRecord(
            key: tree.key,
            family: tree.family,
            project: tree.projectName(home: home),
            cwd: tree.root.cwd,
            mode: tree.mode,
            rootPid: tree.root.pid,
            rootStart: tree.root.startTime,
            sessionID: sessionID,
            title: title,
            firstSeen: now,
            lastSeen: now,
            footprint: tree.footprint,
            processCount: tree.processCount
        )
    }
}

func currentSystem() -> (record: SystemRecord, source: SnapshotSource)? {
    let now = Date().timeIntervalSince1970
    if let store = openStore(), storeIsFresh(store, now: now), let latest = store.latestSystem() {
        return (latest, .store)
    }
    guard let snapshot = collectSystemMemory() else { return nil }
    return (
        SystemRecord(
            ts: now,
            total: snapshot.total,
            used: snapshot.used,
            compressed: snapshot.compressed,
            pressure: snapshot.pressure
        ),
        .live
    )
}

// MARK: - JSON encoding

struct SessionJSON: Codable {
    let key: String
    let family: String
    let project: String
    let title: String?
    let mode: String
    let pid: Int32
    let sessionId: String?
    let footprintBytes: UInt64
    let footprint: String
    let processCount: Int
    let needsAttention: Bool
    let firstSeen: Double
    let lastSeen: Double

    init(_ record: SessionRecord) {
        key = record.key
        family = record.family.rawValue
        project = record.project
        title = record.title
        mode = record.mode.rawValue
        pid = record.rootPid
        sessionId = record.sessionID
        footprintBytes = record.footprint
        footprint = formatBytes(record.footprint)
        processCount = record.processCount
        needsAttention = record.needsAttention
        firstSeen = record.firstSeen
        lastSeen = record.lastSeen
    }
}

struct SystemJSON: Codable {
    let ts: Double
    let totalBytes: UInt64
    let usedBytes: UInt64
    let compressedBytes: UInt64
    let usedFraction: Double
    let pressure: String

    init(_ record: SystemRecord) {
        ts = record.ts
        totalBytes = record.total
        usedBytes = record.used
        compressedBytes = record.compressed
        usedFraction = record.total == 0 ? 0 : Double(record.used) / Double(record.total)
        pressure = record.pressure.label
    }
}

func encodeJSON<Value: Encodable>(_ value: Value) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    guard let data = try? encoder.encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
