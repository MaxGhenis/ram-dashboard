import Foundation
import RambarKit
import RambarSystem

func runTop(watch: Bool) {
    if watch {
        while true {
            print("\u{1B}[2J\u{1B}[H", terminator: "")
            printTop()
            Thread.sleep(forTimeInterval: 5)
        }
    }
    printTop()
}

private func printTop() {
    let now = Date().timeIntervalSince1970

    if let (system, source) = currentSystem() {
        let pressure = system.pressure.label
        let line = "memory \(formatBytes(system.used)) / \(formatBytes(system.total))"
            + " · pressure \(pressure)"
            + " · compressed \(formatBytes(system.compressed))"
            + (source == .live ? " · (live sample — daemon not running)" : "")
        print(line)
    }

    let (sessions, source) = currentSessions()
    guard !sessions.isEmpty else {
        print("no active agent sessions")
        return
    }

    let store = source == .store ? openStore() : nil
    print("")
    print(pad("FAMILY", 8) + pad("PROJECT", 26) + pad("MODE", 10)
        + padLeft("FOOTPRINT", 10) + padLeft("PROCS", 7) + "  TREND")
    for session in sessions {
        var trend = ""
        if let store {
            let history = store.sessionHistory(key: session.key, since: now - 600)
            if isRising(slopeBytesPerSecond: footprintSlope(history)) { trend = "rising" }
        }
        let attention = session.needsAttention ? "  HIGH" : ""
        print(
            pad(session.family.rawValue, 8)
            + pad(String(session.displayName.prefix(24)), 26)
            + pad(session.mode.label, 10)
            + padLeft(formatBytes(session.footprint), 10)
            + padLeft("\(session.processCount)", 7)
            + "  " + trend + attention
        )
    }

    let total = sessions.reduce(UInt64(0)) { $0 + $1.footprint }
    print("")
    print("\(sessions.count) sessions · \(formatBytes(total)) attributed")
}

func runSessions(json: Bool) {
    let (sessions, source) = currentSessions()
    if json {
        struct Output: Codable {
            let source: String
            let sessions: [SessionJSON]
        }
        print(encodeJSON(Output(source: source.rawValue, sessions: sessions.map(SessionJSON.init))))
        return
    }
    for session in sessions {
        let id = session.sessionID.map { " · \($0.prefix(8))" } ?? ""
        print("\(session.displayName) [\(session.family.rawValue)/\(session.mode.label)]"
            + " \(formatBytes(session.footprint)) · \(session.processCount) procs"
            + " · pid \(session.rootPid)\(id)")
    }
}

func runSystem(json: Bool) {
    guard let (system, source) = currentSystem() else {
        FileHandle.standardError.write(Data("rambar: system memory unavailable\n".utf8))
        exit(1)
    }
    if json {
        struct Output: Codable {
            let source: String
            let system: SystemJSON
        }
        print(encodeJSON(Output(source: source.rawValue, system: SystemJSON(system))))
        return
    }
    print("total \(formatBytes(system.total)) · used \(formatBytes(system.used))"
        + " (\(formatPercent(Double(system.used) / Double(system.total))))"
        + " · compressed \(formatBytes(system.compressed))"
        + " · pressure \(system.pressure.label)")
}

func runEvents(since: Double?, json: Bool) {
    guard let store = openStore() else {
        FileHandle.standardError.write(Data("rambar: no store yet — run rambar install-daemon\n".utf8))
        exit(1)
    }
    let events = store.events(since: since ?? Date().timeIntervalSince1970 - 3_600)
    if json {
        struct EventJSON: Codable {
            let ts: Double
            let kind: String
            let payload: String
        }
        print(encodeJSON(events.map { EventJSON(ts: $0.ts, kind: $0.kind, payload: $0.payload) }))
        return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    for event in events {
        let time = formatter.string(from: Date(timeIntervalSince1970: event.ts))
        print("\(time)  \(pad(event.kind, 16))\(event.payload)")
    }
}

func runDoctor() {
    var failures = 0
    func check(_ name: String, _ pass: Bool, hint: String = "") {
        print("\(pass ? "ok" : "FAIL")  \(name)" + (pass || hint.isEmpty ? "" : " — \(hint)"))
        if !pass { failures += 1 }
    }

    let samples = collectProcessSamples()
    check("process sampling (\(samples.count) processes)", samples.count > 50)

    let withFootprint = samples.filter { $0.footprint > 0 }.count
    check("footprint readable for own processes (\(withFootprint))", withFootprint > 10)

    let trees = buildSessionTrees(samples)
    check("session attribution (\(trees.count) sessions)", true)

    check("system memory readable", collectSystemMemory() != nil)

    let storePath = Store.defaultPath()
    let storeExists = FileManager.default.fileExists(atPath: storePath)
    check("store exists at \(storePath)", storeExists, hint: "run rambar install-daemon")

    if storeExists, let store = openStore() {
        let fresh = storeIsFresh(store, now: Date().timeIntervalSince1970)
        check("store fresh (daemon sampling)", fresh, hint: "run rambar install-daemon")
    }

    let loaded = launchctl(["print", "gui/\(getuid())/\(daemonLabel)"]).status == 0
    check("launchd agent loaded", loaded, hint: "run rambar install-daemon")

    exit(failures == 0 ? 0 : 1)
}

func pad(_ string: String, _ width: Int) -> String {
    string.count >= width
        ? string + " "
        : string + String(repeating: " ", count: width - string.count)
}

func padLeft(_ string: String, _ width: Int) -> String {
    string.count >= width
        ? string
        : String(repeating: " ", count: width - string.count) + string
}
