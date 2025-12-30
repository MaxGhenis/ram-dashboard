import { $ } from "bun";

interface AppMemory {
  name: string;
  memory: number;
  processes: number;
  color: string;
}

interface ChromeTab {
  title: string;
  url: string;
  memory: number;
}

interface PythonProcess {
  script: string;
  memory: number;
  pid: number;
}

interface ClaudeSession {
  workingDir: string;
  projectName: string;
  memory: number;
  pid: number;
  isSubagent: boolean;
}

interface VSCodeWorkspace {
  path: string;
  memory: number;
  processes: number;
}

interface SystemMemory {
  total: number;
  used: number;
  free: number;
  apps: AppMemory[];
  chromeTabs: ChromeTab[];
  pythonProcesses: PythonProcess[];
  claudeSessions: ClaudeSession[];
  vscodeWorkspaces: VSCodeWorkspace[];
  timestamp: Date;
}

async function getPythonProcesses(): Promise<PythonProcess[]> {
  try {
    const output = await $`ps aux | grep -i "[p]ython"`.text();
    const lines = output.trim().split('\n').filter(l => l.length > 0);

    const processes: PythonProcess[] = [];

    for (const line of lines) {
      const parts = line.trim().split(/\s+/);
      const pid = parseInt(parts[1]);
      const memory = Math.round(parseInt(parts[5]) / 1024);
      const command = parts.slice(10).join(' ');

      // Extract meaningful script name
      let script = 'Unknown';

      // Match .py files
      const pyMatch = command.match(/([^\s\/]+\.py)/);
      if (pyMatch) {
        script = pyMatch[1];
      }
      // Match known tools
      else if (command.includes('voice-mode')) {
        script = 'voice-mode (MCP)';
      }
      else if (command.includes('ingest')) {
        script = 'Supabase Ingestor';
      }
      else if (command.includes('uv run')) {
        script = 'uv script';
      }
      else if (memory > 100) {
        // Only include significant processes
        script = command.substring(0, 40) + '...';
      } else {
        continue; // Skip small unidentified processes
      }

      if (memory > 10) { // Only show processes > 10MB
        processes.push({ script, memory, pid });
      }
    }

    return processes.sort((a, b) => b.memory - a.memory);
  } catch {
    return [];
  }
}

async function getClaudeSessions(): Promise<ClaudeSession[]> {
  try {
    const output = await $`ps aux | grep "[c]laude"`.text();
    const lines = output.trim().split('\n').filter(l => l.length > 0);

    const sessions: ClaudeSession[] = [];

    for (const line of lines) {
      const parts = line.trim().split(/\s+/);
      const pid = parseInt(parts[1]);
      const memory = Math.round(parseInt(parts[5]) / 1024);
      const command = parts.slice(10).join(' ');

      if (memory < 50) continue; // Skip tiny processes

      // Get working directory
      let workingDir = '';
      try {
        const lsofOutput = await $`lsof -p ${pid} 2>/dev/null | grep cwd | awk '{print $NF}' | head -1`.text();
        workingDir = lsofOutput.trim();
      } catch {}

      // Extract project name from path
      const projectName = workingDir.split('/').filter(p => p && p !== 'Users' && p !== 'maxghenis').slice(-1)[0] || 'Home';

      // Detect if it's a subagent (smaller memory, child of another claude process)
      const isSubagent = memory < 500 && command.includes('claude');

      sessions.push({
        workingDir,
        projectName,
        memory,
        pid,
        isSubagent
      });
    }

    return sessions.sort((a, b) => b.memory - a.memory);
  } catch {
    return [];
  }
}

async function getVSCodeWorkspaces(): Promise<VSCodeWorkspace[]> {
  try {
    const output = await $`ps aux | grep -E "[C]ode Helper|[V]isual Studio Code"`.text();
    const lines = output.trim().split('\n').filter(l => l.length > 0);

    const workspaces: Map<string, { memory: number; processes: number }> = new Map();
    let totalMemory = 0;
    let totalProcesses = 0;

    for (const line of lines) {
      const parts = line.trim().split(/\s+/);
      const memory = Math.round(parseInt(parts[5]) / 1024);
      totalMemory += memory;
      totalProcesses += 1;
    }

    // Get open VS Code windows via AppleScript
    try {
      const script = `tell application "Visual Studio Code" to return name of every window`;
      const windowsOutput = await $`osascript -e ${script}`.text();
      const windows = windowsOutput.trim().split(', ').filter(w => w.length > 0);

      // Distribute memory roughly equally among windows
      const memPerWindow = Math.round(totalMemory / Math.max(windows.length, 1));
      const procsPerWindow = Math.round(totalProcesses / Math.max(windows.length, 1));

      for (const window of windows) {
        // Extract workspace path from window title
        const pathMatch = window.match(/— ([^\[]+)/);
        const path = pathMatch ? pathMatch[1].trim() : window;
        workspaces.set(path, { memory: memPerWindow, processes: procsPerWindow });
      }
    } catch {
      // Fallback - just show total
      workspaces.set('VS Code (total)', { memory: totalMemory, processes: totalProcesses });
    }

    return Array.from(workspaces.entries())
      .map(([path, data]) => ({ path, ...data }))
      .sort((a, b) => b.memory - a.memory);
  } catch {
    return [];
  }
}

async function getChromeTabs(): Promise<ChromeTab[]> {
  try {
    const psOutput = await $`ps aux | grep "[G]oogle Chrome Helper (Renderer)" | sort -k6 -rn`.text();
    const processes = psOutput.trim().split('\n').filter(l => l.length > 0);
    const rendererMemory: number[] = processes.map(line => {
      const parts = line.trim().split(/\s+/);
      return Math.round(parseInt(parts[5] || '0') / 1024);
    });

    const script = `
      tell application "Google Chrome"
        set tabList to ""
        repeat with w from 1 to (count of windows)
          repeat with t from 1 to (count of tabs of window w)
            set tabTitle to title of tab t of window w
            set tabURL to URL of tab t of window w
            set tabList to tabList & tabTitle & "|||" & tabURL & "\\n"
          end repeat
        end repeat
        return tabList
      end tell
    `;
    const tabsOutput = await $`osascript -e ${script}`.text();
    const tabLines = tabsOutput.trim().split('\n').filter(l => l.includes('|||'));

    const tabs: ChromeTab[] = [];
    for (let i = 0; i < tabLines.length; i++) {
      const [title, url] = tabLines[i].split('|||');
      const estimatedMemory = rendererMemory[i] || Math.round(50 + Math.random() * 100);
      tabs.push({
        title: title?.substring(0, 60) || 'Unknown',
        url: url || '',
        memory: estimatedMemory
      });
    }
    return tabs.sort((a, b) => b.memory - a.memory);
  } catch {
    return [];
  }
}

async function getSystemMemory(): Promise<SystemMemory> {
  const totalRam = parseInt(await $`sysctl -n hw.memsize`.text()) / 1024 / 1024 / 1024;
  const vmStat = await $`vm_stat`.text();
  const pageSize = 16384;

  const parseVmStat = (key: string): number => {
    const match = vmStat.match(new RegExp(`${key}:\\s+(\\d+)`));
    return match ? parseInt(match[1]) * pageSize / 1024 / 1024 / 1024 : 0;
  };

  const wired = parseVmStat("Pages wired down");
  const active = parseVmStat("Pages active");
  const compressed = parseVmStat("Pages occupied by compressor");
  const used = wired + active + compressed;

  const psOutput = await $`ps aux`.text();
  const lines = psOutput.trim().split('\n').slice(1);

  const appPatterns: { name: string; pattern: RegExp; color: string }[] = [
    { name: "Chrome", pattern: /Google Chrome|chrome/i, color: "#4285f4" },
    { name: "Claude Code", pattern: /claude/i, color: "#cc785c" },
    { name: "VS Code", pattern: /Visual Studio Code|Code Helper/i, color: "#007acc" },
    { name: "Slack", pattern: /Slack/i, color: "#4a154b" },
    { name: "Python", pattern: /[Pp]ython/i, color: "#3776ab" },
    { name: "Node.js", pattern: /node(?!.*[Cc]ode)/i, color: "#339933" },
    { name: "Next.js", pattern: /next-server/i, color: "#000000" },
    { name: "WhatsApp", pattern: /WhatsApp/i, color: "#25d366" },
    { name: "Obsidian", pattern: /Obsidian/i, color: "#7c3aed" },
    { name: "Docker", pattern: /docker|containerd/i, color: "#2496ed" },
  ];

  const appMemory: Map<string, { memory: number; processes: number; color: string }> = new Map();

  for (const line of lines) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 11) continue;
    const rss = parseInt(parts[5]) / 1024;
    const command = parts.slice(10).join(' ');

    for (const app of appPatterns) {
      if (app.pattern.test(command)) {
        const current = appMemory.get(app.name) || { memory: 0, processes: 0, color: app.color };
        current.memory += rss;
        current.processes += 1;
        appMemory.set(app.name, current);
        break;
      }
    }
  }

  const apps: AppMemory[] = Array.from(appMemory.entries())
    .map(([name, data]) => ({ name, memory: Math.round(data.memory), processes: data.processes, color: data.color }))
    .sort((a, b) => b.memory - a.memory);

  // Fetch all detailed breakdowns in parallel
  const [chromeTabs, pythonProcesses, claudeSessions, vscodeWorkspaces] = await Promise.all([
    getChromeTabs(),
    getPythonProcesses(),
    getClaudeSessions(),
    getVSCodeWorkspaces()
  ]);

  return {
    total: Math.round(totalRam),
    used: Math.round(used * 10) / 10,
    free: Math.round((totalRam - used) * 10) / 10,
    apps,
    chromeTabs,
    pythonProcesses,
    claudeSessions,
    vscodeWorkspaces,
    timestamp: new Date()
  };
}

const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <title>RAM Dashboard</title>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=Chakra+Petch:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --void: #0a0a0f;
      --surface: #12121a;
      --surface-raised: #1a1a24;
      --surface-overlay: #22222e;
      --border: #2a2a3a;
      --border-glow: #3a3a4a;
      --text: #e0e0e8;
      --text-dim: #8888a0;
      --text-muted: #5a5a70;
      --cyan: #00ffd5;
      --cyan-dim: #00c4a7;
      --cyan-glow: rgba(0, 255, 213, 0.15);
      --amber: #ffb800;
      --amber-dim: #cc9400;
      --amber-glow: rgba(255, 184, 0, 0.12);
      --magenta: #ff3d6e;
      --magenta-dim: #cc3158;
      --magenta-glow: rgba(255, 61, 110, 0.12);
      --green: #00ff88;
      --green-dim: #00cc6e;
    }

    * { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: 'IBM Plex Mono', monospace;
      background: var(--void);
      color: var(--text);
      min-height: 100vh;
      line-height: 1.5;
      position: relative;
    }

    /* CRT Scanline Effect */
    body::before {
      content: '';
      position: fixed;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      background: repeating-linear-gradient(
        0deg,
        transparent,
        transparent 2px,
        rgba(0, 0, 0, 0.15) 2px,
        rgba(0, 0, 0, 0.15) 4px
      );
      pointer-events: none;
      z-index: 1000;
    }

    /* Noise texture overlay */
    body::after {
      content: '';
      position: fixed;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noise'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noise)'/%3E%3C/svg%3E");
      opacity: 0.03;
      pointer-events: none;
      z-index: 999;
    }

    .container {
      max-width: 1200px;
      margin: 0 auto;
      padding: 1.5rem;
      position: relative;
      z-index: 1;
    }

    /* Header */
    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 1.5rem;
      padding-bottom: 1rem;
      border-bottom: 1px solid var(--border);
    }

    .header-left {
      display: flex;
      align-items: center;
      gap: 1rem;
    }

    .logo {
      width: 48px;
      height: 48px;
      background: linear-gradient(135deg, var(--surface-raised) 0%, var(--surface) 100%);
      border: 1px solid var(--cyan);
      border-radius: 8px;
      display: flex;
      align-items: center;
      justify-content: center;
      box-shadow: 0 0 20px var(--cyan-glow), inset 0 1px 0 rgba(255,255,255,0.05);
      position: relative;
    }

    .logo::before {
      content: '';
      position: absolute;
      inset: -1px;
      border-radius: 8px;
      background: linear-gradient(135deg, var(--cyan), transparent 60%);
      opacity: 0.3;
      z-index: -1;
    }

    .logo svg {
      width: 26px;
      height: 26px;
      color: var(--cyan);
      filter: drop-shadow(0 0 4px var(--cyan));
    }

    h1 {
      font-family: 'Chakra Petch', sans-serif;
      font-size: 1.5rem;
      font-weight: 700;
      color: var(--text);
      letter-spacing: 0.05em;
      text-transform: uppercase;
    }

    h1 span {
      color: var(--cyan);
      text-shadow: 0 0 10px var(--cyan-glow);
    }

    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      font-size: 0.75rem;
      font-weight: 600;
      padding: 8px 14px;
      border-radius: 4px;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      border: 1px solid;
    }

    .status.ok {
      background: rgba(0, 255, 136, 0.08);
      border-color: var(--green);
      color: var(--green);
      box-shadow: 0 0 15px rgba(0, 255, 136, 0.15);
    }

    .status.warning {
      background: var(--amber-glow);
      border-color: var(--amber);
      color: var(--amber);
      box-shadow: 0 0 15px var(--amber-glow);
    }

    .status.critical {
      background: var(--magenta-glow);
      border-color: var(--magenta);
      color: var(--magenta);
      box-shadow: 0 0 15px var(--magenta-glow);
      animation: criticalPulse 1s ease-in-out infinite;
    }

    @keyframes criticalPulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.7; }
    }

    .status-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      animation: blink 2s ease-in-out infinite;
    }

    .status.ok .status-dot { background: var(--green); box-shadow: 0 0 8px var(--green); }
    .status.warning .status-dot { background: var(--amber); box-shadow: 0 0 8px var(--amber); }
    .status.critical .status-dot { background: var(--magenta); box-shadow: 0 0 8px var(--magenta); }

    @keyframes blink {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.3; }
    }

    /* Main Gauge */
    .gauge-card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 1.5rem;
      margin-bottom: 1.5rem;
      position: relative;
      overflow: hidden;
    }

    .gauge-card::before {
      content: 'SYS.MEM';
      position: absolute;
      top: 12px;
      right: 16px;
      font-size: 0.625rem;
      color: var(--text-muted);
      letter-spacing: 0.1em;
    }

    .gauge-header {
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      margin-bottom: 1rem;
    }

    .gauge-label {
      font-family: 'Chakra Petch', sans-serif;
      font-size: 0.875rem;
      color: var(--text-dim);
      font-weight: 500;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }

    .gauge-value {
      font-size: 3rem;
      font-weight: 600;
      color: var(--cyan);
      letter-spacing: -0.02em;
      text-shadow: 0 0 20px var(--cyan-glow);
    }

    .gauge-value span {
      font-size: 1.25rem;
      color: var(--text-dim);
      font-weight: 400;
    }

    .gauge-bar-container {
      height: 8px;
      background: var(--surface-overlay);
      border-radius: 4px;
      overflow: hidden;
      margin-bottom: 0.5rem;
      border: 1px solid var(--border);
    }

    .stacked-bar {
      display: flex;
      height: 100%;
      border-radius: 3px;
      overflow: hidden;
    }

    .stacked-segment {
      height: 100%;
      transition: width 0.5s cubic-bezier(0.4, 0, 0.2, 1);
      position: relative;
    }

    .stacked-segment::after {
      content: '';
      position: absolute;
      top: 0;
      left: 0;
      right: 0;
      height: 50%;
      background: linear-gradient(to bottom, rgba(255,255,255,0.15), transparent);
    }

    .gauge-labels {
      display: flex;
      justify-content: space-between;
      font-size: 0.6875rem;
      color: var(--text-muted);
    }

    .legend {
      display: flex;
      gap: 1rem;
      margin-top: 1rem;
      padding-top: 1rem;
      border-top: 1px solid var(--border);
      flex-wrap: wrap;
      font-size: 0.75rem;
      color: var(--text-dim);
    }

    /* Section */
    .section {
      margin-bottom: 1.5rem;
    }

    .section-header {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      margin-bottom: 0.875rem;
    }

    .section-number {
      font-size: 0.625rem;
      font-weight: 600;
      color: var(--void);
      background: var(--cyan);
      padding: 2px 6px;
      border-radius: 2px;
      letter-spacing: 0.05em;
    }

    .section-title {
      font-family: 'Chakra Petch', sans-serif;
      font-size: 0.875rem;
      font-weight: 600;
      color: var(--text);
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }

    /* Apps Grid */
    .apps-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
      gap: 0.75rem;
    }

    .app-card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 0.875rem;
      transition: all 0.2s ease;
      position: relative;
      overflow: hidden;
    }

    .app-card::before {
      content: '';
      position: absolute;
      left: 0;
      top: 0;
      bottom: 0;
      width: 3px;
    }

    .app-card:hover {
      border-color: var(--border-glow);
      transform: translateY(-2px);
      box-shadow: 0 4px 20px rgba(0, 0, 0, 0.3);
    }

    .app-name {
      font-family: 'Chakra Petch', sans-serif;
      font-size: 0.75rem;
      font-weight: 600;
      color: var(--text);
      margin-bottom: 0.25rem;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }

    .app-memory {
      font-size: 1.25rem;
      font-weight: 600;
      color: var(--text);
    }

    .app-memory span {
      font-size: 0.6875rem;
      color: var(--text-muted);
      font-weight: 400;
    }

    .app-processes {
      font-size: 0.625rem;
      color: var(--text-muted);
      margin-top: 0.25rem;
    }

    /* Panels Grid */
    .panels-grid {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 0.875rem;
      margin-bottom: 0.875rem;
    }

    .panels-grid-2 {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 0.875rem;
    }

    @media (max-width: 900px) {
      .panels-grid, .panels-grid-2 { grid-template-columns: 1fr; }
    }

    .panel {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 6px;
      overflow: hidden;
    }

    .panel-header {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0.75rem 1rem;
      border-bottom: 1px solid var(--border);
      background: var(--surface-raised);
    }

    .panel-number {
      font-size: 0.5625rem;
      font-weight: 600;
      color: var(--void);
      background: var(--cyan);
      padding: 2px 5px;
      border-radius: 2px;
    }

    .panel-title {
      font-family: 'Chakra Petch', sans-serif;
      font-size: 0.75rem;
      font-weight: 600;
      color: var(--text);
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    .panel-meta {
      font-size: 0.625rem;
      color: var(--text-muted);
      margin-left: auto;
    }

    .panel-content {
      padding: 0.375rem 0;
      max-height: 240px;
      overflow-y: auto;
    }

    .panel-content::-webkit-scrollbar {
      width: 4px;
    }

    .panel-content::-webkit-scrollbar-track {
      background: var(--surface);
    }

    .panel-content::-webkit-scrollbar-thumb {
      background: var(--border);
      border-radius: 2px;
    }

    /* List Items */
    .item {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0.5rem 1rem;
      transition: background 0.15s ease;
      border-left: 2px solid transparent;
    }

    .item:hover {
      background: var(--surface-raised);
      border-left-color: var(--cyan);
    }

    .item-name {
      font-size: 0.75rem;
      color: var(--text);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      flex: 1;
      min-width: 0;
      margin-right: 0.75rem;
    }

    .item-meta {
      font-size: 0.5625rem;
      color: var(--text-muted);
      margin-top: 2px;
    }

    .item-memory {
      font-size: 0.75rem;
      font-weight: 600;
      white-space: nowrap;
    }

    .item-memory.high { color: var(--magenta); text-shadow: 0 0 8px var(--magenta-glow); }
    .item-memory.medium { color: var(--amber); }
    .item-memory.low { color: var(--green); }

    /* Badges */
    .badge, .cc-badge {
      display: inline-flex;
      font-size: 0.5rem;
      font-weight: 600;
      padding: 2px 5px;
      border-radius: 2px;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-left: 6px;
    }

    .badge.main, .cc-badge.main {
      background: var(--amber-glow);
      color: var(--amber);
      border: 1px solid var(--amber-dim);
    }

    .badge.subagent, .cc-badge.subagent {
      background: var(--surface-overlay);
      color: var(--text-muted);
      border: 1px solid var(--border);
    }

    /* Tips Panel */
    .tips-content {
      padding: 0.875rem 1rem;
      font-size: 0.75rem;
      line-height: 1.7;
      color: var(--text-dim);
    }

    .tip-item {
      display: flex;
      align-items: flex-start;
      gap: 0.5rem;
      margin-bottom: 0.5rem;
    }

    .tip-item:last-child {
      margin-bottom: 0;
    }

    .tip-bullet {
      width: 4px;
      height: 4px;
      background: var(--cyan);
      border-radius: 1px;
      margin-top: 0.5rem;
      flex-shrink: 0;
      box-shadow: 0 0 6px var(--cyan);
    }

    /* Footer */
    .footer {
      text-align: center;
      padding: 1.25rem 0;
      margin-top: 1rem;
      border-top: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }

    .footer-main {
      font-size: 0.6875rem;
      color: var(--text-muted);
    }

    .footer-main a {
      color: var(--cyan);
      text-decoration: none;
      transition: all 0.2s;
    }

    .footer-main a:hover {
      text-shadow: 0 0 8px var(--cyan-glow);
    }

    .footer-meta {
      font-size: 0.625rem;
      color: var(--text-muted);
    }

    .footer-meta span {
      color: var(--cyan);
    }

    /* Empty State */
    .empty {
      padding: 1.25rem;
      text-align: center;
      color: var(--text-muted);
      font-size: 0.75rem;
      font-style: italic;
    }

    /* Animations */
    @keyframes slideUp {
      from { opacity: 0; transform: translateY(10px); }
      to { opacity: 1; transform: translateY(0); }
    }

    .section, .panel, .gauge-card {
      animation: slideUp 0.4s ease-out backwards;
    }

    .gauge-card { animation-delay: 0s; }
    .section:nth-of-type(1) { animation-delay: 0.05s; }
    .panels-grid { animation-delay: 0.1s; }
    .panels-grid-2 { animation-delay: 0.15s; }

    /* Grid overlay effect */
    .container::before {
      content: '';
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background-image:
        linear-gradient(var(--border) 1px, transparent 1px),
        linear-gradient(90deg, var(--border) 1px, transparent 1px);
      background-size: 60px 60px;
      opacity: 0.03;
      pointer-events: none;
      z-index: -1;
    }

    /* Loading Overlay */
    .loading-overlay {
      position: fixed;
      inset: 0;
      background: var(--void);
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      z-index: 2000;
      transition: opacity 0.4s ease, visibility 0.4s ease;
    }

    .loading-overlay.hidden {
      opacity: 0;
      visibility: hidden;
    }

    .loading-spinner {
      width: 60px;
      height: 60px;
      position: relative;
    }

    .loading-spinner::before,
    .loading-spinner::after {
      content: '';
      position: absolute;
      inset: 0;
      border: 2px solid transparent;
      border-radius: 50%;
    }

    .loading-spinner::before {
      border-top-color: var(--cyan);
      border-right-color: var(--cyan);
      animation: spin 1s linear infinite;
    }

    .loading-spinner::after {
      inset: 8px;
      border-bottom-color: var(--cyan-dim);
      border-left-color: var(--cyan-dim);
      animation: spin 0.6s linear infinite reverse;
    }

    @keyframes spin {
      to { transform: rotate(360deg); }
    }

    .loading-text {
      margin-top: 1.5rem;
      font-family: 'Chakra Petch', sans-serif;
      font-size: 0.875rem;
      color: var(--cyan);
      text-transform: uppercase;
      letter-spacing: 0.15em;
      animation: loadingPulse 1.5s ease-in-out infinite;
    }

    @keyframes loadingPulse {
      0%, 100% { opacity: 0.5; }
      50% { opacity: 1; }
    }

    .loading-progress {
      margin-top: 0.75rem;
      font-size: 0.6875rem;
      color: var(--text-muted);
      letter-spacing: 0.05em;
    }
  </style>
</head>
<body>
  <div class="loading-overlay" id="loading">
    <div class="loading-spinner"></div>
    <div class="loading-text">Scanning System</div>
    <div class="loading-progress" id="loading-progress">Initializing...</div>
  </div>
  <div class="container">
    <header class="header">
      <div class="header-left">
        <div class="logo">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <rect x="2" y="2" width="20" height="8" rx="2" ry="2"></rect>
            <rect x="2" y="14" width="20" height="8" rx="2" ry="2"></rect>
            <line x1="6" y1="6" x2="6.01" y2="6"></line>
            <line x1="6" y1="18" x2="6.01" y2="18"></line>
          </svg>
        </div>
        <h1><span>RAM</span> Dashboard</h1>
      </div>
      <div class="status ok" id="status">
        <span class="status-dot"></span>
        <span>NOMINAL</span>
      </div>
    </header>

    <div class="gauge-card">
      <div class="gauge-header">
        <span class="gauge-label">System Memory</span>
        <span class="gauge-value" id="used">--<span> / -- GB</span></span>
      </div>
      <div class="gauge-bar-container">
        <div class="stacked-bar" id="stacked-bar"></div>
      </div>
      <div class="gauge-labels">
        <span>0 GB</span>
        <span id="total-label">-- GB</span>
      </div>
      <div class="legend" id="legend"></div>
    </div>

    <section class="section">
      <div class="section-header">
        <span class="section-number">01</span>
        <span class="section-title">Applications</span>
      </div>
      <div class="apps-grid" id="apps"></div>
    </section>

    <div class="panels-grid">
      <div class="panel">
        <div class="panel-header">
          <span class="panel-number">02</span>
          <span class="panel-title">Claude Code</span>
          <span class="panel-meta" id="cc-total"></span>
        </div>
        <div class="panel-content" id="claude-sessions"></div>
      </div>
      <div class="panel">
        <div class="panel-header">
          <span class="panel-number">03</span>
          <span class="panel-title">Python</span>
          <span class="panel-meta" id="py-total"></span>
        </div>
        <div class="panel-content" id="python-processes"></div>
      </div>
      <div class="panel">
        <div class="panel-header">
          <span class="panel-number">04</span>
          <span class="panel-title">VS Code</span>
          <span class="panel-meta" id="vsc-total"></span>
        </div>
        <div class="panel-content" id="vscode-workspaces"></div>
      </div>
    </div>

    <div class="panels-grid-2">
      <div class="panel">
        <div class="panel-header">
          <span class="panel-number">05</span>
          <span class="panel-title">Chrome Tabs</span>
          <span class="panel-meta" id="chrome-total"></span>
        </div>
        <div class="panel-content" id="chrome-tabs"></div>
      </div>
      <div class="panel">
        <div class="panel-header">
          <span class="panel-number">06</span>
          <span class="panel-title">Diagnostics</span>
        </div>
        <div class="tips-content" id="tips"></div>
      </div>
    </div>

    <footer class="footer">
      <p class="footer-main">Built by <a href="https://maxghenis.com" target="_blank">Max Ghenis</a> · <a href="https://github.com/MaxGhenis/ram-dashboard" target="_blank">View on GitHub</a></p>
      <p class="footer-meta">Auto-refresh 3s · Last sync: <span id="timestamp">--</span></p>
    </footer>
  </div>

  <script>
    let isFirstLoad = true;

    function getMemClass(mb) {
      if (mb >= 500) return 'high';
      if (mb >= 200) return 'medium';
      return 'low';
    }

    function formatMem(mb) {
      if (mb >= 1024) return (mb/1024).toFixed(1) + ' GB';
      return mb + ' MB';
    }

    function updateLoadingProgress(msg) {
      const el = document.getElementById('loading-progress');
      if (el) el.textContent = msg;
    }

    function hideLoading() {
      const overlay = document.getElementById('loading');
      if (overlay) overlay.classList.add('hidden');
    }

    async function fetchData() {
      try {
        if (isFirstLoad) updateLoadingProgress('Fetching process data...');
        const res = await fetch('/api/memory');
        if (isFirstLoad) updateLoadingProgress('Parsing memory stats...');
        const data = await res.json();

        const pct = (data.used / data.total * 100).toFixed(0);
        document.getElementById('used').innerHTML = data.used.toFixed(1) + '<span> / ' + data.total + ' GB</span>';
        document.getElementById('total-label').textContent = data.total + ' GB';

        const status = document.getElementById('status');
        if (pct > 90) {
          status.innerHTML = '<span class="status-dot"></span><span>CRITICAL</span>';
          status.className = 'status critical';
        } else if (pct > 75) {
          status.innerHTML = '<span class="status-dot"></span><span>WARNING</span>';
          status.className = 'status warning';
        } else {
          status.innerHTML = '<span class="status-dot"></span><span>NOMINAL</span>';
          status.className = 'status ok';
        }

        // Stacked bar
        document.getElementById('stacked-bar').innerHTML = data.apps
          .filter(a => a.memory > 100)
          .map(a => '<div class="stacked-segment" style="width:' + (a.memory/data.total/1024*100) + '%;background:' + a.color + '" title="' + a.name + ': ' + formatMem(a.memory) + '"></div>')
          .join('');

        document.getElementById('legend').innerHTML = data.apps
          .filter(a => a.memory > 100)
          .map(a => '<span style="display:flex;align-items:center;gap:5px;"><span style="width:8px;height:8px;border-radius:2px;background:' + a.color + ';box-shadow:0 0 6px ' + a.color + '50"></span>' + a.name + '</span>')
          .join('');

        // Apps grid
        document.getElementById('apps').innerHTML = data.apps
          .filter(app => app.memory > 50)
          .map(app =>
            '<div class="app-card" style="--app-color:' + app.color + '">' +
            '<style>.app-card[style*="' + app.color + '"]::before{background:' + app.color + ';box-shadow:0 0 8px ' + app.color + '}</style>' +
            '<div class="app-name">' + app.name + '</div>' +
            '<div class="app-memory">' + formatMem(app.memory) + '</div>' +
            '<div class="app-processes">' + app.processes + ' proc</div>' +
            '</div>'
          ).join('');

        // Claude Sessions
        const ccTotal = data.claudeSessions.reduce((s, c) => s + c.memory, 0);
        const mainSessions = data.claudeSessions.filter(c => c.memory > 200).length;
        document.getElementById('cc-total').textContent = mainSessions + ' main · ' + formatMem(ccTotal);
        document.getElementById('claude-sessions').innerHTML = data.claudeSessions
          .filter(c => c.memory > 50)
          .map(c =>
            '<div class="item">' +
            '<div class="item-name">' + c.projectName +
            '<span class="cc-badge ' + (c.memory > 500 ? 'main' : 'subagent') + '">' + (c.memory > 500 ? 'MAIN' : 'SUB') + '</span>' +
            '<div class="item-meta">PID ' + c.pid + '</div></div>' +
            '<div class="item-memory ' + getMemClass(c.memory) + '">' + formatMem(c.memory) + '</div>' +
            '</div>'
          ).join('') || '<div class="empty">No active sessions</div>';

        // Python Processes
        const pyTotal = data.pythonProcesses.reduce((s, p) => s + p.memory, 0);
        document.getElementById('py-total').textContent = data.pythonProcesses.length + ' proc · ' + formatMem(pyTotal);
        document.getElementById('python-processes').innerHTML = data.pythonProcesses
          .map(p =>
            '<div class="item">' +
            '<div class="item-name">' + p.script + '<div class="item-meta">PID ' + p.pid + '</div></div>' +
            '<div class="item-memory ' + getMemClass(p.memory) + '">' + formatMem(p.memory) + '</div>' +
            '</div>'
          ).join('') || '<div class="empty">No Python processes</div>';

        // VS Code
        const vscTotal = data.vscodeWorkspaces.reduce((s, v) => s + v.memory, 0);
        document.getElementById('vsc-total').textContent = data.vscodeWorkspaces.length + ' ws · ' + formatMem(vscTotal);
        document.getElementById('vscode-workspaces').innerHTML = data.vscodeWorkspaces
          .map(v =>
            '<div class="item">' +
            '<div class="item-name">' + v.path + '</div>' +
            '<div class="item-memory ' + getMemClass(v.memory) + '">' + formatMem(v.memory) + '</div>' +
            '</div>'
          ).join('') || '<div class="empty">VS Code not running</div>';

        // Chrome Tabs
        const chromeTotal = data.chromeTabs.reduce((s, t) => s + t.memory, 0);
        document.getElementById('chrome-total').textContent = data.chromeTabs.length + ' tabs · ' + formatMem(chromeTotal);
        document.getElementById('chrome-tabs').innerHTML = data.chromeTabs
          .slice(0, 15)
          .map(tab =>
            '<div class="item">' +
            '<div class="item-name" title="' + tab.url + '">' + tab.title + '</div>' +
            '<div class="item-memory ' + getMemClass(tab.memory) + '">' + tab.memory + ' MB</div>' +
            '</div>'
          ).join('');

        // Tips
        const tips = [];
        const chromeApp = data.apps.find(a => a.name === 'Chrome');
        if (chromeApp && chromeApp.memory > 10000) tips.push('Chrome using ' + formatMem(chromeApp.memory) + ' — consider closing tabs');
        if (mainSessions > 3) tips.push(mainSessions + ' Claude Code sessions active — consider closing some');
        const bigPy = data.pythonProcesses.find(p => p.memory > 1000);
        if (bigPy) tips.push('Python "' + bigPy.script + '" using ' + formatMem(bigPy.memory));
        if (pct > 80) tips.push('Memory pressure high (' + pct + '%) — close unused apps');
        if (tips.length === 0) tips.push('All systems nominal');
        document.getElementById('tips').innerHTML = tips.map(t => '<div class="tip-item"><span class="tip-bullet"></span>' + t + '</div>').join('');

        document.getElementById('timestamp').textContent = new Date(data.timestamp).toLocaleTimeString();

        if (isFirstLoad) {
          updateLoadingProgress('Complete');
          setTimeout(hideLoading, 200);
          isFirstLoad = false;
        }
      } catch (e) {
        console.error('Fetch failed:', e);
        if (isFirstLoad) {
          updateLoadingProgress('Connection error, retrying...');
        }
      }
    }

    fetchData();
    setInterval(fetchData, 3000);
  </script>
</body>
</html>`;

const server = Bun.serve({
  port: 3333,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === '/api/memory') {
      const data = await getSystemMemory();
      return new Response(JSON.stringify(data), {
        headers: { 'Content-Type': 'application/json' }
      });
    }
    return new Response(html, { headers: { 'Content-Type': 'text/html' } });
  }
});

console.log('RAM Dashboard running at http://localhost:' + server.port);
