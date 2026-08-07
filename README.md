# Rambar

A session-first memory monitor for agent-heavy Macs, as a native menu bar app, a CLI, and an MCP server.

Rambar starts with **agent sessions**: a Claude Code, Codex, or Gemini root process plus every helper descended from it (MCP servers, shells, and dev servers). It finds sessions whether they are hosted by a desktop app, a terminal or tmux pane, or a headless worker with no TTY. An opt-in **Group by app** view starts instead from familiar app and runtime groups, with agent rows expandable into their sessions.

## Why sessions and process groups

Per-session attribution answers which agent session is the memory hog, what a closed session left behind, and why there are 22 resident copies of the same MCP server. The optional process-group view answers whether Claude, Chrome, an editor, or something else is responsible at a glance.

Each listed process belongs to one top-level group. Agent-owned Node and Python helpers stay with their agent instead of being counted again as standalone runtimes. Rambar groups previously unknown applications from their outer `.app` bundle, so the list does not depend on a fixed app allowlist.

Group values sum macOS per-process physical footprints. Shared memory can appear in more than one process, so adding rows together can exceed the system-used number. The system header and kernel pressure remain the authoritative machine-wide signals.

## What it shows

- **Session-centric overview** — agent sessions grouped by family, with process grouping available as an opt-in view
- **Expandable agent detail** — per-session footprint across the full process tree, with hosting mode (desktop / terminal / headless), project, process count, and helper breakdown
- **Kernel pressure, not percent** — the menu bar tint and alerts key off macOS memory-pressure events; 81% used with a calm kernel is fine, and Rambar says so
- **Alerts that name the mover** — a pressure transition reports the session that grew most in the last 10 minutes, not just a level
- **Hygiene** — helpers that outlived their session (with one-click reclaim), and the same helper binary resident many times across sessions
- **History** — a 60-minute sparkline in the panel; a week of samples in SQLite for "what ate RAM overnight"

## Runaway session controls

Expand a Claude Code, Codex, or Gemini session to interrupt its agent root,
pause or resume its verified process tree, or ask the whole tree to end. Rambar
checks the process start time immediately before every signal, so a recycled
PID cannot redirect an action to an unrelated process. Ending a session first
uses confirmed `SIGTERM`. If the verified tree remains alive, Rambar reports
the failure and offers a separately confirmed **Force End** using `SIGKILL`.
Resume is verified after signal delivery; terminal job-control failures are
reported with the required `fg` recovery instead of being called successful.

An optional **Auto-pause runaway sessions** toggle lives in the panel menu and
is off by default. When enabled, the collector pauses the process that crossed
the threshold after two consecutive suspicious samples. Targeting the culprit
instead of the whole tree keeps the agent root and its terminal foreground
ownership intact when a helper runs away. The guard triggers when either:

- that process uses at least 30% of physical RAM while macOS reports warning or critical pressure; or
- it uses at least 15% of RAM and grew by at least 10% of physical RAM within 30 seconds.

Automatic containment only uses `SIGSTOP`. The affected session remains visible
with a pause indicator and can be resumed or ended from its expanded row.

## Architecture

One repo, three consumers of one collection pipeline:

- `rambar collect` — a launchd agent sampling every 5 s via libproc syscalls (no `ps`, no parsing, no AppleScript) into `~/.rambar/rambar.sqlite`
- **Rambar.app** — a SwiftUI MenuBarExtra that only reads the store; the UI owns no collection state
- `rambar` CLI + `rambar mcp` — the same ledger for terminals and for agents themselves; a Claude session can ask how much memory it is using

`RambarKit` (process grouping, session attribution, orphan tracking, dedup, and trends) is a pure library with no system dependencies, tested against fixture topologies modeled on real machines.

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

When upgrading an existing installation, run the new bundled collector once so
the background service and menu bar app stay on the same version:

```bash
/Applications/Rambar.app/Contents/MacOS/rambar-cli install-daemon
```

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

The original monitor (Chrome tabs and the retro theme) lives in [`RAMBar/`](RAMBar/) and still builds:

```bash
cd RAMBar && xcodebuild -scheme RAMBar -configuration Release build
```

## License

[Unlicense](LICENSE) — public domain.
