import Foundation
import SQLite3
import RambarKit

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A session as persisted: identity plus the latest observation. The daemon
/// writes these; the CLI, face, and MCP server only read.
public struct SessionRecord: Sendable {
    public let key: String
    public let family: AgentFamily
    public let project: String
    public let cwd: String?
    public let mode: SessionMode
    public let rootPid: Int32
    public let rootStart: Double
    public let sessionID: String?
    public let firstSeen: Double
    public let lastSeen: Double
    public let footprint: UInt64
    public let processCount: Int

    public var needsAttention: Bool {
        sessionNeedsAttention(footprint: footprint, processCount: processCount)
    }

    public init(
        key: String, family: AgentFamily, project: String, cwd: String?,
        mode: SessionMode, rootPid: Int32, rootStart: Double, sessionID: String?,
        firstSeen: Double, lastSeen: Double, footprint: UInt64, processCount: Int
    ) {
        self.key = key
        self.family = family
        self.project = project
        self.cwd = cwd
        self.mode = mode
        self.rootPid = rootPid
        self.rootStart = rootStart
        self.sessionID = sessionID
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.footprint = footprint
        self.processCount = processCount
    }
}

public struct StoredEvent: Sendable {
    public let ts: Double
    public let kind: String
    public let payload: String
}

public struct SystemRecord: Sendable {
    public let ts: Double
    public let total: UInt64
    public let used: UInt64
    public let compressed: UInt64
    public let pressure: PressureLevel

    public init(ts: Double, total: UInt64, used: UInt64, compressed: UInt64, pressure: PressureLevel) {
        self.ts = ts
        self.total = total
        self.used = used
        self.compressed = compressed
        self.pressure = pressure
    }
}

public enum StoreError: Error {
    case open(String)
    case exec(String)
}

/// SQLite persistence at ~/.rambar/rambar.sqlite. WAL mode so the single
/// writer (daemon) and many readers (CLI, face, MCP) never block each other.
public final class Store {
    public static func defaultPath(home: String = NSHomeDirectory()) -> String {
        home + "/.rambar/rambar.sqlite"
    }

    private var db: OpaquePointer?

    public init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA busy_timeout=2000")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS session(
                key TEXT PRIMARY KEY,
                family TEXT NOT NULL,
                project TEXT NOT NULL,
                cwd TEXT,
                mode TEXT NOT NULL,
                root_pid INTEGER NOT NULL,
                root_start REAL NOT NULL,
                session_id TEXT,
                first_seen REAL NOT NULL,
                last_seen REAL NOT NULL,
                footprint INTEGER NOT NULL DEFAULT 0,
                procs INTEGER NOT NULL DEFAULT 0
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS sample(
                ts REAL NOT NULL,
                key TEXT NOT NULL,
                footprint INTEGER NOT NULL,
                procs INTEGER NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_sample_key_ts ON sample(key, ts)")
        try execute("CREATE INDEX IF NOT EXISTS idx_sample_ts ON sample(ts)")
        try execute("""
            CREATE TABLE IF NOT EXISTS system_sample(
                ts REAL PRIMARY KEY,
                total INTEGER NOT NULL,
                used INTEGER NOT NULL,
                free INTEGER NOT NULL,
                compressed INTEGER NOT NULL,
                pressure INTEGER NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS event(
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                payload TEXT NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_event_ts ON event(ts)")
        try execute("""
            CREATE TABLE IF NOT EXISTS orphan_state(
                id INTEGER PRIMARY KEY CHECK (id = 1),
                ts REAL NOT NULL,
                count INTEGER NOT NULL,
                footprint INTEGER NOT NULL,
                pids TEXT NOT NULL,
                dups TEXT NOT NULL DEFAULT '[]'
            )
            """)
    }

    // MARK: - Low-level helpers

    private func execute(_ sql: String, _ binds: [Bind] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, binds)
        let status = sqlite3_step(statement)
        // PRAGMA statements report their result as a row.
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
        }
    }

    private enum Bind {
        case text(String)
        case textOrNull(String?)
        case int(Int64)
        case real(Double)
    }

    private func bind(_ statement: OpaquePointer?, _ binds: [Bind]) {
        for (offset, value) in binds.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            case .textOrNull(let string):
                if let string {
                    sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case .int(let integer):
                sqlite3_bind_int64(statement, index, integer)
            case .real(let double):
                sqlite3_bind_double(statement, index, double)
            }
        }
    }

    private func query<Row>(
        _ sql: String,
        _ binds: [Bind] = [],
        row: (OpaquePointer) -> Row
    ) -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, binds)
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let statement { rows.append(row(statement)) }
        }
        return rows
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : text(statement, column)
    }

    // MARK: - Writes (daemon only)

    public func record(
        ts: Double,
        trees: [AgentSessionTree],
        sessionIDs: [String: String],
        home: String
    ) throws {
        try execute("BEGIN")
        do {
            for tree in trees {
                let footprint = Int64(bitPattern: tree.footprint)
                try execute("""
                    INSERT INTO session(key, family, project, cwd, mode, root_pid, root_start,
                                        session_id, first_seen, last_seen, footprint, procs)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(key) DO UPDATE SET
                        last_seen=excluded.last_seen,
                        footprint=excluded.footprint,
                        procs=excluded.procs,
                        mode=excluded.mode,
                        session_id=COALESCE(excluded.session_id, session.session_id)
                    """, [
                        .text(tree.key),
                        .text(tree.family.rawValue),
                        .text(tree.projectName(home: home)),
                        .textOrNull(tree.root.cwd),
                        .text(tree.mode.rawValue),
                        .int(Int64(tree.root.pid)),
                        .real(tree.root.startTime),
                        .textOrNull(sessionIDs[tree.key]),
                        .real(ts),
                        .real(ts),
                        .int(footprint),
                        .int(Int64(tree.processCount)),
                    ])
                try execute(
                    "INSERT INTO sample(ts, key, footprint, procs) VALUES(?,?,?,?)",
                    [.real(ts), .text(tree.key), .int(footprint), .int(Int64(tree.processCount))]
                )
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func record(ts: Double, system: SystemMemorySnapshot) throws {
        try execute("""
            INSERT OR REPLACE INTO system_sample(ts, total, used, free, compressed, pressure)
            VALUES(?,?,?,?,?,?)
            """, [
                .real(ts),
                .int(Int64(bitPattern: system.total)),
                .int(Int64(bitPattern: system.used)),
                .int(Int64(bitPattern: system.free)),
                .int(Int64(bitPattern: system.compressed)),
                .int(Int64(system.pressure.rawValue)),
            ])
    }

    public struct DuplicateJSON: Codable, Sendable {
        public let basename: String
        public let count: Int
        public let footprint: UInt64

        public init(basename: String, count: Int, footprint: UInt64) {
            self.basename = basename
            self.count = count
            self.footprint = footprint
        }
    }

    public func recordOrphanState(
        ts: Double, report: OrphanReport, duplicates: [DuplicateGroup]
    ) throws {
        let pids = report.identities.map { String($0.pid) }.sorted().joined(separator: ",")
        let dups = duplicates.map {
            DuplicateJSON(basename: $0.basename, count: $0.count, footprint: $0.footprint)
        }
        let dupsJSON = (try? JSONEncoder().encode(dups))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        try execute("""
            INSERT OR REPLACE INTO orphan_state(id, ts, count, footprint, pids, dups)
            VALUES(1,?,?,?,?,?)
            """, [
                .real(ts),
                .int(Int64(report.count)),
                .int(Int64(bitPattern: report.footprint)),
                .text(pids),
                .text(dupsJSON),
            ])
    }

    public struct OrphanState: Sendable {
        public let ts: Double
        public let count: Int
        public let footprint: UInt64
        public let pids: [Int32]
        public let duplicates: [DuplicateJSON]
    }

    public func latestOrphanState() -> OrphanState? {
        query("SELECT ts, count, footprint, pids, dups FROM orphan_state WHERE id = 1") { statement in
            let dupsText = Self.text(statement, 4)
            let dups = (try? JSONDecoder().decode(
                [DuplicateJSON].self, from: Data(dupsText.utf8)
            )) ?? []
            return OrphanState(
                ts: sqlite3_column_double(statement, 0),
                count: Int(sqlite3_column_int64(statement, 1)),
                footprint: UInt64(bitPattern: sqlite3_column_int64(statement, 2)),
                pids: Self.text(statement, 3).split(separator: ",").compactMap { Int32($0) },
                duplicates: dups
            )
        }.first
    }

    public func recordEvent(ts: Double, kind: String, payload: String) throws {
        try execute(
            "INSERT INTO event(ts, kind, payload) VALUES(?,?,?)",
            [.real(ts), .text(kind), .text(payload)]
        )
    }

    /// Raw 5s samples are kept for 2 hours, one per minute for 7 days,
    /// nothing beyond that. Runs transactionally on the daemon's cadence.
    public func compact(now: Double) throws {
        let weekAgo = now - 7 * 86_400
        let twoHoursAgo = now - 2 * 3_600
        try execute("BEGIN")
        do {
            try execute("DELETE FROM sample WHERE ts < ?", [.real(weekAgo)])
            try execute("""
                DELETE FROM sample WHERE ts < ? AND rowid NOT IN (
                    SELECT MIN(rowid) FROM sample WHERE ts < ?
                    GROUP BY key, CAST(ts / 60 AS INTEGER)
                )
                """, [.real(twoHoursAgo), .real(twoHoursAgo)])
            try execute("DELETE FROM system_sample WHERE ts < ?", [.real(weekAgo)])
            try execute("""
                DELETE FROM system_sample WHERE ts < ? AND rowid NOT IN (
                    SELECT MIN(rowid) FROM system_sample WHERE ts < ?
                    GROUP BY CAST(ts / 60 AS INTEGER)
                )
                """, [.real(twoHoursAgo), .real(twoHoursAgo)])
            try execute("DELETE FROM event WHERE ts < ?", [.real(weekAgo)])
            try execute("DELETE FROM session WHERE last_seen < ?", [.real(weekAgo)])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Reads

    private static func sessionRecord(_ statement: OpaquePointer) -> SessionRecord {
        SessionRecord(
            key: text(statement, 0),
            family: AgentFamily(rawValue: text(statement, 1)) ?? .claude,
            project: text(statement, 2),
            cwd: optionalText(statement, 3),
            mode: SessionMode(rawValue: text(statement, 4)) ?? .headless,
            rootPid: Int32(sqlite3_column_int64(statement, 5)),
            rootStart: sqlite3_column_double(statement, 6),
            sessionID: optionalText(statement, 7),
            firstSeen: sqlite3_column_double(statement, 8),
            lastSeen: sqlite3_column_double(statement, 9),
            footprint: UInt64(bitPattern: sqlite3_column_int64(statement, 10)),
            processCount: Int(sqlite3_column_int64(statement, 11))
        )
    }

    private static let sessionColumns =
        "key, family, project, cwd, mode, root_pid, root_start, session_id, first_seen, last_seen, footprint, procs"

    /// Sessions observed within the staleness window, largest first.
    public func activeSessions(now: Double, staleAfter: Double = 20) -> [SessionRecord] {
        query("""
            SELECT \(Self.sessionColumns) FROM session
            WHERE last_seen >= ? ORDER BY footprint DESC
            """, [.real(now - staleAfter)], row: Self.sessionRecord)
    }

    public func sessionHistory(key: String, since: Double) -> [(time: Double, bytes: UInt64)] {
        query(
            "SELECT ts, footprint FROM sample WHERE key = ? AND ts >= ? ORDER BY ts",
            [.text(key), .real(since)]
        ) { statement in
            (sqlite3_column_double(statement, 0),
             UInt64(bitPattern: sqlite3_column_int64(statement, 1)))
        }
    }

    public func systemHistory(since: Double) -> [SystemRecord] {
        query(
            "SELECT ts, total, used, compressed, pressure FROM system_sample WHERE ts >= ? ORDER BY ts",
            [.real(since)]
        ) { statement in
            SystemRecord(
                ts: sqlite3_column_double(statement, 0),
                total: UInt64(bitPattern: sqlite3_column_int64(statement, 1)),
                used: UInt64(bitPattern: sqlite3_column_int64(statement, 2)),
                compressed: UInt64(bitPattern: sqlite3_column_int64(statement, 3)),
                pressure: PressureLevel(rawValue: Int(sqlite3_column_int64(statement, 4))) ?? .normal
            )
        }
    }

    public func latestSystem() -> SystemRecord? {
        systemHistory(since: 0).last
    }

    public func events(since: Double) -> [StoredEvent] {
        query(
            "SELECT ts, kind, payload FROM event WHERE ts > ? ORDER BY ts",
            [.real(since)]
        ) { statement in
            StoredEvent(
                ts: sqlite3_column_double(statement, 0),
                kind: Self.text(statement, 1),
                payload: Self.text(statement, 2)
            )
        }
    }
}
