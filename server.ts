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
  <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Source+Sans+3:wght@400;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --ink: #0f172a;
      --ink-soft: #334155;
      --ink-muted: #64748b;
      --cream: #fefdf8;
      --cream-dark: #faf9f4;
      --amber: #f59e0b;
      --amber-dark: #d97706;
      --amber-glow: rgba(245, 158, 11, 0.15);
      --success: #22c55e;
      --warning: #eab308;
      --danger: #ef4444;
      --shadow-sm: 0 1px 2px rgba(15, 23, 42, 0.05);
      --shadow-md: 0 4px 6px -1px rgba(15, 23, 42, 0.07), 0 2px 4px -1px rgba(15, 23, 42, 0.04);
      --shadow-lg: 0 10px 15px -3px rgba(15, 23, 42, 0.08), 0 4px 6px -2px rgba(15, 23, 42, 0.04);
      --radius-sm: 6px;
      --radius-md: 10px;
      --radius-lg: 14px;
    }

    * { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: 'Source Sans 3', -apple-system, BlinkMacSystemFont, sans-serif;
      background: var(--cream);
      color: var(--ink);
      min-height: 100vh;
      padding: 2rem;
      line-height: 1.5;
    }

    .container {
      max-width: 1100px;
      margin: 0 auto;
    }

    /* Header */
    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 2.5rem;
      padding-bottom: 1.5rem;
      border-bottom: 1px solid rgba(15, 23, 42, 0.08);
    }

    .header-left {
      display: flex;
      align-items: center;
      gap: 1rem;
    }

    .logo {
      width: 42px;
      height: 42px;
      background: linear-gradient(135deg, var(--ink) 0%, var(--ink-soft) 100%);
      border-radius: var(--radius-md);
      display: flex;
      align-items: center;
      justify-content: center;
      box-shadow: var(--shadow-md);
    }

    .logo svg {
      width: 24px;
      height: 24px;
      color: white;
    }

    h1 {
      font-size: 1.75rem;
      font-weight: 700;
      background: linear-gradient(135deg, var(--ink) 0%, var(--ink-soft) 100%);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
    }

    .status-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.75rem;
      font-weight: 600;
      padding: 6px 12px;
      border-radius: 20px;
      letter-spacing: 0.02em;
    }

    .status-badge.ok {
      background: rgba(34, 197, 94, 0.12);
      color: #16a34a;
    }
    .status-badge.warning {
      background: rgba(234, 179, 8, 0.15);
      color: #a16207;
    }
    .status-badge.critical {
      background: rgba(239, 68, 68, 0.12);
      color: #dc2626;
    }

    .status-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      animation: pulse 2s ease-in-out infinite;
    }

    .status-badge.ok .status-dot { background: #22c55e; }
    .status-badge.warning .status-dot { background: #eab308; }
    .status-badge.critical .status-dot { background: #ef4444; }

    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.5; }
    }

    /* Main Gauge */
    .gauge-card {
      background: white;
      border: 1px solid rgba(15, 23, 42, 0.08);
      border-radius: var(--radius-lg);
      padding: 1.75rem;
      margin-bottom: 2rem;
      box-shadow: var(--shadow-sm);
    }

    .gauge-header {
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      margin-bottom: 1rem;
    }

    .gauge-label {
      font-size: 0.875rem;
      color: var(--ink-muted);
      font-weight: 500;
    }

    .gauge-value {
      font-family: 'JetBrains Mono', monospace;
      font-size: 2.75rem;
      font-weight: 600;
      color: var(--ink);
      letter-spacing: -0.02em;
    }

    .gauge-value span {
      font-size: 1.25rem;
      color: var(--ink-muted);
      font-weight: 500;
    }

    .gauge-bar-container {
      height: 12px;
      background: var(--cream-dark);
      border-radius: 6px;
      overflow: hidden;
      margin-bottom: 0.75rem;
    }

    .stacked-bar {
      display: flex;
      height: 100%;
      border-radius: 6px;
      overflow: hidden;
    }

    .stacked-segment {
      height: 100%;
      transition: width 0.5s cubic-bezier(0.4, 0, 0.2, 1);
    }

    .gauge-labels {
      display: flex;
      justify-content: space-between;
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.75rem;
      color: var(--ink-muted);
    }

    .legend {
      display: flex;
      gap: 1.25rem;
      margin-top: 1rem;
      padding-top: 1rem;
      border-top: 1px solid rgba(15, 23, 42, 0.06);
      flex-wrap: wrap;
    }

    .legend-item {
      display: flex;
      align-items: center;
      gap: 6px;
      font-size: 0.8125rem;
      color: var(--ink-soft);
    }

    .legend-dot {
      width: 10px;
      height: 10px;
      border-radius: 3px;
    }

    /* Section Headers */
    .section {
      margin-bottom: 2rem;
    }

    .section-header {
      display: flex;
      align-items: baseline;
      gap: 0.75rem;
      margin-bottom: 1rem;
    }

    .section-number {
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.8125rem;
      font-weight: 600;
      color: var(--amber-dark);
    }

    .section-title {
      font-size: 1.125rem;
      font-weight: 600;
      color: var(--ink);
    }

    .section-meta {
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.75rem;
      color: var(--ink-muted);
      margin-left: auto;
    }

    /* Apps Grid */
    .apps-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
      gap: 0.875rem;
    }

    .app-card {
      background: white;
      border: 1px solid rgba(15, 23, 42, 0.08);
      border-radius: var(--radius-md);
      padding: 1rem;
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
      background: var(--app-color);
    }

    .app-card:hover {
      border-color: rgba(15, 23, 42, 0.15);
      box-shadow: var(--shadow-md);
      transform: translateY(-1px);
    }

    .app-name {
      font-size: 0.8125rem;
      font-weight: 600;
      color: var(--ink);
      margin-bottom: 0.375rem;
    }

    .app-memory {
      font-family: 'JetBrains Mono', monospace;
      font-size: 1.375rem;
      font-weight: 600;
      color: var(--ink);
    }

    .app-memory span {
      font-size: 0.75rem;
      color: var(--ink-muted);
      font-weight: 500;
    }

    .app-processes {
      font-size: 0.6875rem;
      color: var(--ink-muted);
      margin-top: 0.25rem;
    }

    /* Panels Grid */
    .panels-grid {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 1rem;
      margin-bottom: 1.5rem;
    }

    .panels-grid-2 {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 1rem;
    }

    @media (max-width: 900px) {
      .panels-grid, .panels-grid-2 { grid-template-columns: 1fr; }
    }

    .panel {
      background: white;
      border: 1px solid rgba(15, 23, 42, 0.08);
      border-radius: var(--radius-lg);
      overflow: hidden;
    }

    .panel-header {
      display: flex;
      align-items: baseline;
      gap: 0.5rem;
      padding: 1rem 1.25rem;
      border-bottom: 1px solid rgba(15, 23, 42, 0.06);
      background: var(--cream-dark);
    }

    .panel-number {
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.75rem;
      font-weight: 600;
      color: var(--amber-dark);
    }

    .panel-title {
      font-size: 0.875rem;
      font-weight: 600;
      color: var(--ink);
    }

    .panel-meta {
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.6875rem;
      color: var(--ink-muted);
      margin-left: auto;
    }

    .panel-content {
      padding: 0.5rem 0;
      max-height: 280px;
      overflow-y: auto;
    }

    .panel-content::-webkit-scrollbar {
      width: 4px;
    }

    .panel-content::-webkit-scrollbar-track {
      background: transparent;
    }

    .panel-content::-webkit-scrollbar-thumb {
      background: rgba(15, 23, 42, 0.15);
      border-radius: 2px;
    }

    /* List Items */
    .item {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0.625rem 1.25rem;
      transition: background 0.15s ease;
    }

    .item:hover {
      background: var(--cream-dark);
    }

    .item-content {
      flex: 1;
      min-width: 0;
      margin-right: 1rem;
    }

    .item-name {
      font-size: 0.8125rem;
      font-weight: 500;
      color: var(--ink);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }

    .item-meta {
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.6875rem;
      color: var(--ink-muted);
      margin-top: 2px;
    }

    .item-memory {
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.8125rem;
      font-weight: 600;
      white-space: nowrap;
    }

    .item-memory.high { color: var(--danger); }
    .item-memory.medium { color: var(--amber-dark); }
    .item-memory.low { color: #16a34a; }

    /* Badges */
    .badge {
      display: inline-flex;
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.625rem;
      font-weight: 600;
      padding: 2px 6px;
      border-radius: 4px;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }

    .badge.main {
      background: var(--amber-glow);
      color: var(--amber-dark);
    }

    .badge.subagent {
      background: rgba(15, 23, 42, 0.08);
      color: var(--ink-muted);
    }

    /* Tips Panel */
    .tips-content {
      padding: 1rem 1.25rem;
      font-size: 0.875rem;
      line-height: 1.7;
      color: var(--ink-soft);
    }

    .tip {
      display: flex;
      align-items: flex-start;
      gap: 0.5rem;
      margin-bottom: 0.5rem;
    }

    .tip:last-child {
      margin-bottom: 0;
    }

    .tip::before {
      content: '';
      width: 6px;
      height: 6px;
      background: var(--amber);
      border-radius: 50%;
      margin-top: 0.5rem;
      flex-shrink: 0;
    }

    /* Footer */
    .footer {
      text-align: center;
      padding-top: 1.5rem;
      margin-top: 1rem;
      border-top: 1px solid rgba(15, 23, 42, 0.06);
    }

    .footer-text {
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.75rem;
      color: var(--ink-muted);
    }

    .footer-text span {
      color: var(--amber-dark);
    }

    /* Empty State */
    .empty {
      padding: 1.5rem;
      text-align: center;
      color: var(--ink-muted);
      font-size: 0.8125rem;
    }

    /* Animations */
    @keyframes fadeIn {
      from { opacity: 0; transform: translateY(8px); }
      to { opacity: 1; transform: translateY(0); }
    }

    .section {
      animation: fadeIn 0.4s ease-out;
    }

    .section:nth-child(2) { animation-delay: 0.05s; }
    .section:nth-child(3) { animation-delay: 0.1s; }
    .section:nth-child(4) { animation-delay: 0.15s; }
  </style>
</head>
<body>
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
        <h1>RAM Dashboard</h1>
      </div>
      <div class="status-badge ok" id="status">
        <span class="status-dot"></span>
        <span>OK</span>
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
          <span class="panel-title">Recommendations</span>
        </div>
        <div class="tips-content" id="tips"></div>
      </div>
    </div>

    <footer class="footer">
      <p class="footer-text">Auto-refreshes every 3s · Last update: <span id="timestamp">--</span></p>
    </footer>
  </div>

  <script>
    function getMemClass(mb) {
      if (mb >= 500) return 'high';
      if (mb >= 200) return 'medium';
      return 'low';
    }

    function formatMem(mb) {
      if (mb >= 1024) return (mb/1024).toFixed(1) + ' GB';
      return mb + ' MB';
    }

    async function fetchData() {
      try {
        const res = await fetch('/api/memory');
        const data = await res.json();

        const pct = (data.used / data.total * 100).toFixed(0);
        document.getElementById('used').innerHTML = data.used.toFixed(1) + '<span> / ' + data.total + ' GB</span>';
        document.getElementById('total-label').textContent = data.total + ' GB';

        const status = document.getElementById('status');
        if (pct > 90) { status.textContent = 'CRITICAL'; status.className = 'status critical'; }
        else if (pct > 75) { status.textContent = 'WARNING'; status.className = 'status warning'; }
        else { status.textContent = 'OK'; status.className = 'status'; }

        // Stacked bar
        const totalMem = data.apps.reduce((s, a) => s + a.memory, 0);
        document.getElementById('stacked-bar').innerHTML = data.apps
          .filter(a => a.memory > 100)
          .map(a => '<div class="stacked-segment" style="width:' + (a.memory/data.total/1024*100) + '%;background:' + a.color + '" title="' + a.name + ': ' + formatMem(a.memory) + '"></div>')
          .join('');

        document.getElementById('legend').innerHTML = data.apps
          .filter(a => a.memory > 100)
          .map(a => '<span style="display:flex;align-items:center;gap:4px;"><span style="width:10px;height:10px;border-radius:2px;background:' + a.color + '"></span>' + a.name + '</span>')
          .join('');

        // Apps grid
        document.getElementById('apps').innerHTML = data.apps
          .filter(app => app.memory > 50)
          .map(app =>
            '<div class="app-card" style="border-color: ' + app.color + '">' +
            '<div class="app-name">' + app.name + '</div>' +
            '<div class="app-memory">' + formatMem(app.memory) + '</div>' +
            '<div class="app-processes">' + app.processes + ' processes</div>' +
            '</div>'
          ).join('');

        // Claude Sessions
        const ccTotal = data.claudeSessions.reduce((s, c) => s + c.memory, 0);
        const mainSessions = data.claudeSessions.filter(c => c.memory > 200).length;
        document.getElementById('cc-total').textContent = mainSessions + ' main, ' + formatMem(ccTotal);
        document.getElementById('claude-sessions').innerHTML = data.claudeSessions
          .filter(c => c.memory > 50)
          .map(c =>
            '<div class="item">' +
            '<div class="item-name">' + c.projectName +
            '<span class="cc-badge ' + (c.memory > 500 ? 'main' : 'subagent') + '">' + (c.memory > 500 ? 'main' : 'subagent') + '</span>' +
            '<div class="item-meta">PID ' + c.pid + '</div></div>' +
            '<div class="item-memory ' + getMemClass(c.memory) + '">' + formatMem(c.memory) + '</div>' +
            '</div>'
          ).join('') || '<div style="color:#666;font-size:13px;">No active sessions</div>';

        // Python Processes
        const pyTotal = data.pythonProcesses.reduce((s, p) => s + p.memory, 0);
        document.getElementById('py-total').textContent = data.pythonProcesses.length + ' processes, ' + formatMem(pyTotal);
        document.getElementById('python-processes').innerHTML = data.pythonProcesses
          .map(p =>
            '<div class="item">' +
            '<div class="item-name">' + p.script + '<div class="item-meta">PID ' + p.pid + '</div></div>' +
            '<div class="item-memory ' + getMemClass(p.memory) + '">' + formatMem(p.memory) + '</div>' +
            '</div>'
          ).join('') || '<div style="color:#666;font-size:13px;">No Python processes</div>';

        // VS Code
        const vscTotal = data.vscodeWorkspaces.reduce((s, v) => s + v.memory, 0);
        document.getElementById('vsc-total').textContent = data.vscodeWorkspaces.length + ' workspaces, ' + formatMem(vscTotal);
        document.getElementById('vscode-workspaces').innerHTML = data.vscodeWorkspaces
          .map(v =>
            '<div class="item">' +
            '<div class="item-name">' + v.path + '</div>' +
            '<div class="item-memory ' + getMemClass(v.memory) + '">' + formatMem(v.memory) + '</div>' +
            '</div>'
          ).join('') || '<div style="color:#666;font-size:13px;">VS Code not running</div>';

        // Chrome Tabs
        const chromeTotal = data.chromeTabs.reduce((s, t) => s + t.memory, 0);
        document.getElementById('chrome-total').textContent = data.chromeTabs.length + ' tabs, ' + formatMem(chromeTotal);
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
        if (chromeApp && chromeApp.memory > 10000) tips.push('Chrome using ' + formatMem(chromeApp.memory) + ' - consider closing tabs');
        if (mainSessions > 3) tips.push(mainSessions + ' Claude Code sessions - consider closing some');
        const bigPy = data.pythonProcesses.find(p => p.memory > 1000);
        if (bigPy) tips.push('Python script "' + bigPy.script + '" using ' + formatMem(bigPy.memory));
        if (pct > 80) tips.push('Memory pressure high (' + pct + '%) - close unused apps');
        if (tips.length === 0) tips.push('Memory usage looks healthy!');
        document.getElementById('tips').innerHTML = tips.map(t => '• ' + t).join('<br>');

        document.getElementById('timestamp').textContent = new Date(data.timestamp).toLocaleTimeString();
      } catch (e) {
        console.error('Failed to fetch:', e);
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
