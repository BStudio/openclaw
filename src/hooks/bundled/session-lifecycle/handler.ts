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

const PID_FILE = "/tmp/session-keep-alive.pid";
const LOG_FILE = "/tmp/session-keep-alive.log";

function timestamp(): string {
  return new Date().toTimeString().slice(0, 8);
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

async function startKeepAliveDaemon(): Promise<{ started: boolean; pid?: number; error?: string }> {
  try {
    // Check if already running
    try {
      const pidContent = await fs.readFile(PID_FILE, "utf-8");
      const pid = parseInt(pidContent.trim(), 10);

      // Check if process is alive
      try {
        process.kill(pid, 0);
        return { started: false, pid, error: "Already running" };
      } catch {
        // Process not running, remove stale PID file
        await fs.unlink(PID_FILE).catch(() => {});
      }
    } catch {
      // PID file doesn't exist, proceed to start
    }

    // Find OpenClaw project root (where scripts/ is located)
    const projectRoot = process.cwd();
    const scriptPath = path.join(projectRoot, "scripts/session-keep-alive-daemon.sh");

    // Check if script exists
    try {
      await fs.access(scriptPath);
    } catch {
      return { started: false, error: "Script not found" };
    }

    // Start the daemon in the background
    const { stdout } = await execAsync(
      `nohup bash "${scriptPath}" 60 > "${LOG_FILE}" 2>&1 & echo $!`,
      {
        cwd: projectRoot,
      },
    );

    const pid = parseInt(stdout.trim(), 10);

    if (!isNaN(pid)) {
      await fs.writeFile(PID_FILE, pid.toString());
      return { started: true, pid };
    }

    return { started: false, error: "Failed to start daemon" };
  } catch (err) {
    return { started: false, error: String(err) };
  }
}

async function stopKeepAliveDaemon(): Promise<{ stopped: boolean; error?: string }> {
  try {
    // Read PID file
    const pidContent = await fs.readFile(PID_FILE, "utf-8");
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
      await fs.unlink(PID_FILE).catch(() => {});

      return { stopped: true };
    } catch {
      // Process doesn't exist
      await fs.unlink(PID_FILE).catch(() => {});
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
  console.log(`🚀 [${timestamp()}] Session started: ${event.sessionId} ${sessionInfo}`);

  // Start keep-alive daemon
  const result = await startKeepAliveDaemon();

  if (result.started) {
    console.log(`   Keep-alive daemon: STARTED (PID: ${result.pid})`);
  } else if (result.error === "Already running") {
    console.log(`   Keep-alive daemon: ALREADY RUNNING (PID: ${result.pid})`);
  } else {
    console.log(`   Keep-alive daemon: FAILED (${result.error})`);
  }
}

// Session end hook
export async function session_end(
  event: PluginHookSessionEndEvent,
  _ctx: PluginHookSessionContext,
): Promise<void> {
  const duration = event.durationMs ? formatDuration(event.durationMs) : "unknown";

  console.log(`👋 [${timestamp()}] Session ended: ${event.sessionId}`);
  console.log(`   Duration: ${duration}`);
  console.log(`   Messages: ${event.messageCount}`);

  // Stop keep-alive daemon
  const result = await stopKeepAliveDaemon();

  if (result.stopped) {
    console.log(`   Keep-alive daemon: STOPPED`);
  } else {
    console.log(`   Keep-alive daemon: ${result.error || "Not running"}`);
  }
}

// Gateway stop hook
export async function gateway_stop(
  event: PluginHookGatewayStopEvent,
  _ctx: PluginHookGatewayContext,
): Promise<void> {
  const reason = event.reason ? ` (${event.reason})` : "";
  console.log(`🛑 [${timestamp()}] Gateway stopping${reason}`);

  // Stop keep-alive daemon
  const result = await stopKeepAliveDaemon();

  if (result.stopped) {
    console.log(`   Keep-alive daemon: STOPPED`);
  }
}

// Default export for backward compatibility
export default {
  session_start,
  session_end,
  gateway_stop,
};
