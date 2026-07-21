# Rambar

A memory ledger for agent fleets, as a native macOS menu bar app, a CLI, and an MCP server.

Rambar attributes RAM to **agent sessions** — a Claude Code, Codex, or Gemini root process plus every helper descended from it (MCP servers, shells, dev servers) — instead of to app names. It finds sessions however they are hosted: the Claude desktop app, a terminal or tmux pane, or headless workers with no TTY at all.

## Why sessions, not apps

Per-app accounting answers "how much is node using." It cannot answer the questions that matter when you run many agents: which session is the memory hog, what did a closed session leave behind, and why are there 22 resident copies of the same MCP server. The first live run of Rambar on the machine it was built on found ~3 GB of exactly that duplication — the same four MCP servers loaded once per session, 22 times each.

## What it shows

- **Per-session footprint** — `ri_phys_footprint` (what Activity Monitor's Memory column reports) summed over each session's full process tree, with hosting mode (desktop / terminal / headless), project, process count, and expandable helper breakdown
- **Kernel pressure, not percent** — the menu bar tint and alerts key off macOS memory-pressure events; 81% used with a calm kernel is fine, and Rambar says so
- **Alerts that name the mover** — a pressure transition reports the session that grew most in the last 10 minutes, not just a level
- **Hygiene** — helpers that outlived their session (with one-click reclaim), and the same helper binary resident many times across sessions
- **History** — a 60-minute sparkline in the panel; a week of samples in SQLite for "what ate RAM overnight"

## Architecture

One repo, three consumers of one collection pipeline:

- `rambar collect` — a launchd agent sampling every 5 s via libproc syscalls (no `ps`, no parsing, no AppleScript) into `~/.rambar/rambar.sqlite`
- **Rambar.app** — a SwiftUI MenuBarExtra that only reads the store; the UI owns no collection state
- `rambar` CLI + `rambar mcp` — the same ledger for terminals and for agents themselves; a Claude session can ask how much memory it is using

`RambarKit` (attribution: tree grouping, orphan tracking, dedup, trends) is a pure library with no system dependencies, tested against fixture topologies modeled on real machines.

## Install

```bash
git clone https://github.com/MaxGhenis/rambar.git
cd rambar
swift build -c release
./.build/release/rambar install-daemon   # start the collector (launchd)
scripts/bundle-app.sh release            # assemble dist/Rambar.app
open dist/Rambar.app                     # menu bar face
```

`rambar doctor` verifies every layer. `rambar uninstall-daemon` removes the collector and keeps your data.

## CLI

```
rambar top             # sessions and system memory (works even without the daemon)
rambar sessions --json # machine-readable session list
rambar events          # pressure transitions, orphans, session starts/ends
rambar doctor          # check collection, store freshness, launchd
rambar mcp             # MCP stdio server: memory_status, list_sessions, session_history
```

Register the MCP server so agents can read the ledger:

```bash
claude mcp add rambar -- ~/.rambar/bin/rambar mcp
```

## Requirements

- macOS 14.0+
- No special permissions: collection is same-user libproc; no AppleScript, no accessibility, no screen recording

## v1

The original app-centric monitor (per-app rows, Chrome tabs, retro theme) lives in [`RAMBar/`](RAMBar/) and still builds:

```bash
cd RAMBar && xcodebuild -scheme RAMBar -configuration Release build
```

## License

[Unlicense](LICENSE) — public domain.
