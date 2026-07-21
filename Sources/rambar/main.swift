import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let flags = Set(arguments.dropFirst().filter { $0.hasPrefix("--") })
let options = parseOptions(Array(arguments.dropFirst()))

switch command {
case "top":
    runTop(watch: flags.contains("--watch"))
case "sessions":
    runSessions(json: flags.contains("--json"))
case "system":
    runSystem(json: flags.contains("--json"))
case "events":
    runEvents(since: options["--since"].flatMap(Double.init), json: flags.contains("--json"))
case "collect":
    runCollect(once: flags.contains("--once"))
case "install-daemon":
    runInstallDaemon()
case "uninstall-daemon":
    runUninstallDaemon()
case "doctor":
    runDoctor()
case "mcp":
    runMCPServer()
case "help", "--help", "-h":
    printUsage()
default:
    FileHandle.standardError.write(Data("rambar: unknown command '\(command)'\n\n".utf8))
    printUsage()
    exit(64)
}

func parseOptions(_ arguments: [String]) -> [String: String] {
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument.hasPrefix("--"), index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("--") {
            options[argument] = arguments[index + 1]
            index += 2
        } else {
            index += 1
        }
    }
    return options
}

func printUsage() {
    print("""
    rambar — memory ledger for agent fleets

    usage: rambar <command>

      top [--watch]        current sessions and system memory
      sessions [--json]    active agent sessions
      system [--json]      system memory and pressure
      events [--since T]   recorded events (pressure, orphans, sessions)
      collect [--once]     run the sampling loop in the foreground
      install-daemon       install and start the launchd collector
      uninstall-daemon     stop and remove the launchd collector
      doctor               check collection, store freshness, and the daemon
      mcp                  serve rambar tools over MCP stdio
    """)
}
