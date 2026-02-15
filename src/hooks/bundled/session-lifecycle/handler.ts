import type {
  PluginHookSessionStartEvent,
  PluginHookSessionEndEvent,
  PluginHookGatewayStopEvent,
  PluginHookSessionContext,
  PluginHookGatewayContext,
} from "openclaw/plugin-sdk";
import { exec } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const execAsync = promisify(exec);

const ACTIVITY_MONITOR_PID_FILE = "/tmp/claude-code-activity-monitor.pid";
const ACTIVITY_MONITOR_LOG_FILE = "/tmp/claude-code-activity-monitor.log";
const HOOK_LOG_FILE = "/tmp/session-lifecycle-hook.log";
const STATUS_FILE = "/tmp/session-lifecycle-status.json";

function timestamp(): string {
  return new Date().toISOString();
}

function shortTimestamp(): string {
  return new Date().toTimeString().slice(0, 8);
}

async function logToFile(message: string): Promise<void> {
  try {
    const logEntry = `[${timestamp()}] ${message}\n`;
    await fs.appendFile(HOOK_LOG_FILE, logEntry);
  } catch {
    // Silently fail if we can't write to log file
  }
}

function logBoth(message: string): void {
  console.log(message);
  void logToFile(message);
}

async function updateStatusFile(status: {
  event: "session_start" | "session_end" | "gateway_stop";
  sessionId?: string;
  timestamp: string;
  daemonStatus?: string;
  daemonPid?: number;
  duration?: string;
  messageCount?: number;
  resumedFrom?: string;
}): Promise<void> {
  try {
    await fs.writeFile(STATUS_FILE, JSON.stringify(status, null, 2));
  } catch {
    // Silently fail if we can't write status file
  }
}

function formatDuration(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);

  if (hours > 0) {
    return `${hours}h ${minutes % 60}m ${seconds % 60}s`;
  }
  if (minutes > 0) {
    return `${minutes}m ${seconds % 60}s`;
  }
  return `${seconds}s`;
}

async function startActivityMonitor(): Promise<{ started: boolean; pid?: number; error?: string }> {
  try {
    // Check if already running
    try {
      const pidContent = await fs.readFile(ACTIVITY_MONITOR_PID_FILE, "utf-8");
      const pid = parseInt(pidContent.trim(), 10);

      // Check if process is alive
      try {
        process.kill(pid, 0);
        return { started: false, pid, error: "Already running" };
      } catch {
        // Process not running, remove stale PID file
        await fs.unlink(ACTIVITY_MONITOR_PID_FILE).catch(() => {});
      }
    } catch {
      // PID file doesn't exist, proceed to start
    }

    // Find OpenClaw project root (where scripts/ is located)
    const projectRoot = process.cwd();
    const scriptPath = path.join(projectRoot, "scripts/claude-code-activity-monitor.ts");

    // Check if script exists
    try {
      await fs.access(scriptPath);
    } catch {
      return { started: false, error: "Script not found" };
    }

    // Detect if we're in a Claude Code session (check for known env vars or container indicators)
    const isClaudeCodeSession =
      process.env.CLAUDE_CODE_SESSION ||
      process.env.CODESPACE_NAME ||
      process.env.GITPOD_WORKSPACE_ID ||
      false;

    if (!isClaudeCodeSession) {
      // Not in a Claude Code session, skip activity monitor
      return { started: false, error: "Not in Claude Code session (skipped)" };
    }

    // Start the activity monitor in the background
    // Use tsx to run TypeScript directly, with verbose output for debugging
    const { stdout } = await execAsync(
      `nohup node --import tsx "${scriptPath}" --verbose > "${ACTIVITY_MONITOR_LOG_FILE}" 2>&1 & echo $!`,
      {
        cwd: projectRoot,
      },
    );

    const pid = parseInt(stdout.trim(), 10);

    if (!isNaN(pid)) {
      await fs.writeFile(ACTIVITY_MONITOR_PID_FILE, pid.toString());
      return { started: true, pid };
    }

    return { started: false, error: "Failed to start activity monitor" };
  } catch (err) {
    return { started: false, error: String(err) };
  }
}

async function stopActivityMonitor(): Promise<{ stopped: boolean; error?: string }> {
  try {
    // Read PID file
    const pidContent = await fs.readFile(ACTIVITY_MONITOR_PID_FILE, "utf-8");
    const pid = parseInt(pidContent.trim(), 10);

    if (isNaN(pid)) {
      return { stopped: false, error: "Invalid PID" };
    }

    // Kill the process
    try {
      process.kill(pid, "SIGTERM");
      // Give it a moment to die gracefully
      await new Promise((resolve) => setTimeout(resolve, 500));

      // Check if still alive
      try {
        process.kill(pid, 0);
        // Still alive, force kill
        process.kill(pid, "SIGKILL");
      } catch {
        // Process is dead
      }

      // Remove PID file
      await fs.unlink(ACTIVITY_MONITOR_PID_FILE).catch(() => {});

      return { stopped: true };
    } catch {
      // Process doesn't exist
      await fs.unlink(ACTIVITY_MONITOR_PID_FILE).catch(() => {});
      return { stopped: true };
    }
  } catch {
    // PID file doesn't exist
    return { stopped: false, error: "Not running" };
  }
}

// Session start hook
export async function session_start(
  event: PluginHookSessionStartEvent,
  _ctx: PluginHookSessionContext,
): Promise<void> {
  const sessionInfo = event.resumedFrom ? `(resumed from ${event.resumedFrom})` : "";
  logBoth(`🚀 [${shortTimestamp()}] Session started: ${event.sessionId} ${sessionInfo}`);

  // Start Claude Code activity monitor
  const result = await startActivityMonitor();

  let daemonStatus = "";
  if (result.started) {
    daemonStatus = `STARTED (PID: ${result.pid})`;
    logBoth(`   Claude Code activity monitor: ${daemonStatus}`);
  } else if (result.error === "Already running") {
    daemonStatus = `ALREADY RUNNING (PID: ${result.pid})`;
    logBoth(`   Claude Code activity monitor: ${daemonStatus}`);
  } else {
    daemonStatus = `SKIPPED (${result.error})`;
    // Don't log as error if it's just skipped due to not being in Claude Code
    if (result.error?.includes("Not in Claude Code")) {
      logBoth(`   Claude Code activity monitor: ${daemonStatus}`);
    } else {
      logBoth(`   Claude Code activity monitor: FAILED (${result.error})`);
    }
  }

  // Update status file
  await updateStatusFile({
    event: "session_start",
    sessionId: event.sessionId,
    timestamp: timestamp(),
    daemonStatus,
    daemonPid: result.pid,
    resumedFrom: event.resumedFrom,
  });
}

// Session end hook
export async function session_end(
  event: PluginHookSessionEndEvent,
  _ctx: PluginHookSessionContext,
): Promise<void> {
  const duration = event.durationMs ? formatDuration(event.durationMs) : "unknown";

  logBoth(`👋 [${shortTimestamp()}] Session ended: ${event.sessionId}`);
  logBoth(`   Duration: ${duration}`);
  logBoth(`   Messages: ${event.messageCount}`);

  // Stop Claude Code activity monitor
  const result = await stopActivityMonitor();

  let daemonStatus = "";
  if (result.stopped) {
    daemonStatus = "STOPPED";
    logBoth(`   Claude Code activity monitor: ${daemonStatus}`);
  } else {
    daemonStatus = result.error || "Not running";
    logBoth(`   Claude Code activity monitor: ${daemonStatus}`);
  }

  // Update status file
  await updateStatusFile({
    event: "session_end",
    sessionId: event.sessionId,
    timestamp: timestamp(),
    daemonStatus,
    duration,
    messageCount: event.messageCount,
  });
}

// Gateway stop hook
export async function gateway_stop(
  event: PluginHookGatewayStopEvent,
  _ctx: PluginHookGatewayContext,
): Promise<void> {
  const reason = event.reason ? ` (${event.reason})` : "";
  logBoth(`🛑 [${shortTimestamp()}] Gateway stopping${reason}`);

  // Stop Claude Code activity monitor
  const result = await stopActivityMonitor();

  let daemonStatus = "";
  if (result.stopped) {
    daemonStatus = "STOPPED";
    logBoth(`   Claude Code activity monitor: ${daemonStatus}`);
  }

  // Update status file
  await updateStatusFile({
    event: "gateway_stop",
    timestamp: timestamp(),
    daemonStatus,
  });
}

// Default export for backward compatibility
export default {
  session_start,
  session_end,
  gateway_stop,
};
