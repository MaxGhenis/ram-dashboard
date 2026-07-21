import Foundation
import RambarSystem

let daemonLabel = "com.maxghenis.rambar.collector"

func runCollect(once: Bool) {
    guard let store = try? Store(path: Store.defaultPath()) else {
        FileHandle.standardError.write(Data("rambar: cannot open store\n".utf8))
        exit(1)
    }
    let daemon = Daemon(store: store)
    if once {
        daemon.tick()
        return
    }
    daemon.run()
}

func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (1, "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private var installedBinaryPath: String { NSHomeDirectory() + "/.rambar/bin/rambar" }
private var plistPath: String {
    NSHomeDirectory() + "/Library/LaunchAgents/\(daemonLabel).plist"
}

func runInstallDaemon() {
    let fileManager = FileManager.default
    do {
        // Copy the running binary to a stable path so rebuilds don't strand launchd.
        let rawPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let selfPath = (rawPath as NSString).resolvingSymlinksInPath
        guard FileManager.default.isExecutableFile(atPath: selfPath) else {
            FileHandle.standardError.write(Data("rambar: cannot resolve own binary path\n".utf8))
            exit(1)
        }

        try fileManager.createDirectory(
            atPath: (installedBinaryPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: installedBinaryPath) {
            try fileManager.removeItem(atPath: installedBinaryPath)
        }
        try fileManager.copyItem(atPath: selfPath, toPath: installedBinaryPath)

        let logDirectory = NSHomeDirectory() + "/.rambar"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installedBinaryPath)</string>
                <string>collect</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Background</string>
            <key>StandardOutPath</key><string>\(logDirectory)/collector.log</string>
            <key>StandardErrorPath</key><string>\(logDirectory)/collector.log</string>
        </dict>
        </plist>
        """
        try fileManager.createDirectory(
            atPath: (plistPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

        _ = launchctl(["bootout", "gui/\(getuid())/\(daemonLabel)"])
        // launchd needs a beat to drain a booted-out label before the same
        // label can bootstrap again; retry briefly instead of failing.
        var result = (status: Int32(1), output: "")
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            result = launchctl(["bootstrap", "gui/\(getuid())", plistPath])
            if result.status == 0 { break }
        }
        guard result.status == 0 else {
            FileHandle.standardError.write(Data("rambar: launchctl bootstrap failed: \(result.output)\n".utf8))
            exit(1)
        }
        print("installed \(daemonLabel)")
        print("binary  \(installedBinaryPath)")
        print("store   \(Store.defaultPath())")
        print("remove with: rambar uninstall-daemon")
    } catch {
        FileHandle.standardError.write(Data("rambar: install failed: \(error)\n".utf8))
        exit(1)
    }
}

func runUninstallDaemon() {
    _ = launchctl(["bootout", "gui/\(getuid())/\(daemonLabel)"])
    try? FileManager.default.removeItem(atPath: plistPath)
    print("removed \(daemonLabel) (data kept at ~/.rambar)")
}
