#!/usr/bin/env node --import tsx
/**
 * Claude Code Activity Monitor
 *
 * Keeps Claude Code container sessions alive by detecting OpenClaw agent activity
 * and signaling to Claude Code via periodic stdout pings.
 *
 * Problem:
 * - Claude Code containers auto-close after ~5min of inactivity
 * - OpenClaw agents run inside the container but their activity is invisible to Claude Code
 * - Container closes prematurely even when agents are actively working
 *
 * Solution:
 * - Monitor OpenClaw session store for activity (updatedAt changes)
 * - When agents are active, send periodic "pings" to Claude Code via stdout
 * - This keeps the container session alive until all agents are idle
 *
 * Usage:
 *   tsx scripts/claude-code-activity-monitor.ts [options]
 *
 * Options:
 *   --check-interval=SECONDS      How often to check for activity (default: 30)
 *   --ping-interval=SECONDS       How often to ping when active (default: 60)
 *   --idle-threshold=MINUTES      Consider sessions idle after N minutes (default: 3)
 *   --agent-id=ID                 Agent ID to monitor (default: default)
 *   --dry-run                     Log activity without sending pings
 *   --verbose                     Enable verbose logging
 *   --help, -h                    Show this help
 */

import { loadConfig } from "../src/config/config.js";
import { loadSessionStore, resolveStorePath } from "../src/config/sessions.js";
import { createSubsystemLogger } from "../src/logging/subsystem.js";

const log = createSubsystemLogger("claude-code-activity");

type ActivityMonitorOptions = {
  /** How often to check for activity (milliseconds) */
  checkIntervalMs: number;
  /** How often to ping Claude Code when active (milliseconds) */
  pingIntervalMs: number;
  /** Consider sessions idle after this many minutes */
  idleThresholdMinutes: number;
  /** Agent ID to monitor */
  agentId: string;
  /** Dry run mode (don't send pings) */
  dryRun: boolean;
  /** Verbose logging */
  verbose: boolean;
};

const DEFAULT_CHECK_INTERVAL_MS = 30_000; // 30 seconds
const DEFAULT_PING_INTERVAL_MS = 60_000; // 1 minute
const DEFAULT_IDLE_THRESHOLD_MINUTES = 3; // 3 minutes

export class ClaudeCodeActivityMonitor {
  private checkTimer: NodeJS.Timeout | null = null;
  private pingTimer: NodeJS.Timeout | null = null;
  private stopped = false;
  private lastActivityTime = 0;
  private lastPingTime = 0;
  private readonly options: ActivityMonitorOptions;

  constructor(options: Partial<ActivityMonitorOptions> = {}) {
    this.options = {
      checkIntervalMs: options.checkIntervalMs ?? DEFAULT_CHECK_INTERVAL_MS,
      pingIntervalMs: options.pingIntervalMs ?? DEFAULT_PING_INTERVAL_MS,
      idleThresholdMinutes: options.idleThresholdMinutes ?? DEFAULT_IDLE_THRESHOLD_MINUTES,
      agentId: options.agentId ?? "default",
      dryRun: options.dryRun ?? false,
      verbose: options.verbose ?? false,
    };
  }

  start(): void {
    if (this.checkTimer) {
      log.warn("Activity monitor already running");
      return;
    }

    log.info("Starting Claude Code activity monitor", {
      checkIntervalMs: this.options.checkIntervalMs,
      pingIntervalMs: this.options.pingIntervalMs,
      idleThresholdMinutes: this.options.idleThresholdMinutes,
      agentId: this.options.agentId,
      dryRun: this.options.dryRun,
    });

    this.scheduleNextCheck();
  }

  stop(): void {
    if (this.stopped) {
      return;
    }

    this.stopped = true;

    if (this.checkTimer) {
      clearTimeout(this.checkTimer);
      this.checkTimer = null;
    }

    if (this.pingTimer) {
      clearTimeout(this.pingTimer);
      this.pingTimer = null;
    }

    log.info("Activity monitor stopped");
  }

  private scheduleNextCheck(): void {
    if (this.stopped) {
      return;
    }

    this.checkTimer = setTimeout(async () => {
      this.checkTimer = null;

      try {
        await this.checkActivity();
      } catch (err) {
        if (this.options.verbose) {
          log.error("Activity check failed", { error: String(err) });
        }
      }

      this.scheduleNextCheck();
    }, this.options.checkIntervalMs);

    this.checkTimer.unref?.();
  }

  private async checkActivity(): Promise<void> {
    const now = Date.now();
    const cfg = loadConfig();
    const storePath = resolveStorePath(cfg.session?.store, { agentId: this.options.agentId });

    // Load session store
    const store = loadSessionStore(storePath);
    const sessionKeys = Object.keys(store);

    if (sessionKeys.length === 0) {
      if (this.options.verbose) {
        log.debug("No sessions found");
      }
      this.lastActivityTime = 0;
      return;
    }

    // Find the most recent activity timestamp
    const idleThresholdMs = this.options.idleThresholdMinutes * 60_000;
    const cutoffTime = now - idleThresholdMs;

    let mostRecentActivity = 0;
    let activeSessionCount = 0;

    for (const key of sessionKeys) {
      const entry = store[key];
      if (!entry) {
        continue;
      }

      const updatedAt = entry.updatedAt ?? 0;
      if (updatedAt >= cutoffTime) {
        activeSessionCount++;
        mostRecentActivity = Math.max(mostRecentActivity, updatedAt);
      }
    }

    // Update activity tracking
    const wasActive = this.lastActivityTime > 0;
    const isActive = mostRecentActivity > 0;

    if (isActive) {
      this.lastActivityTime = mostRecentActivity;

      if (!wasActive) {
        log.info("Agents became active", {
          activeSessionCount,
          mostRecentActivityAge: Math.floor((now - mostRecentActivity) / 1000) + "s",
        });
      } else if (this.options.verbose) {
        log.debug("Agents still active", {
          activeSessionCount,
          mostRecentActivityAge: Math.floor((now - mostRecentActivity) / 1000) + "s",
        });
      }

      // Send ping if needed
      await this.sendPingIfNeeded();
    } else {
      if (wasActive) {
        log.info("All agents idle");
      }
      this.lastActivityTime = 0;
    }
  }

  private async sendPingIfNeeded(): Promise<void> {
    const now = Date.now();
    const timeSinceLastPing = now - this.lastPingTime;

    if (timeSinceLastPing >= this.options.pingIntervalMs) {
      await this.sendPing();
      this.lastPingTime = now;
    }
  }

  private async sendPing(): Promise<void> {
    if (this.options.dryRun) {
      log.info("[DRY RUN] Would send ping to Claude Code");
      return;
    }

    // Send a minimal keepalive ping to stdout
    // This signals activity to Claude Code without cluttering logs
    const timestamp = new Date().toISOString();
    console.log(`[openclaw-activity] ${timestamp}`);

    if (this.options.verbose) {
      log.debug("Sent ping to Claude Code");
    }
  }
}

// CLI entry point
async function main() {
  const args = process.argv.slice(2);

  if (args.includes("--help") || args.includes("-h")) {
    console.log(`
Claude Code Activity Monitor

Keeps Claude Code container sessions alive by detecting OpenClaw agent activity.

Usage:
  tsx scripts/claude-code-activity-monitor.ts [options]

Options:
  --check-interval=SECONDS      How often to check for activity (default: 30)
  --ping-interval=SECONDS       How often to ping when active (default: 60)
  --idle-threshold=MINUTES      Consider sessions idle after N minutes (default: 3)
  --agent-id=ID                 Agent ID to monitor (default: default)
  --dry-run                     Log activity without sending pings
  --verbose                     Enable verbose logging
  --help, -h                    Show this help

Examples:
  # Run with defaults
  tsx scripts/claude-code-activity-monitor.ts

  # Check every 15 seconds, ping every 30 seconds
  tsx scripts/claude-code-activity-monitor.ts --check-interval=15 --ping-interval=30

  # Verbose mode
  tsx scripts/claude-code-activity-monitor.ts --verbose

  # Dry run to see what would happen
  tsx scripts/claude-code-activity-monitor.ts --dry-run --verbose
    `);
    process.exit(0);
  }

  const dryRun = args.includes("--dry-run");
  const verbose = args.includes("--verbose");

  const checkInterval = parseInt(
    args.find((arg) => arg.startsWith("--check-interval="))?.split("=")[1] ?? "30",
    10,
  );
  const pingInterval = parseInt(
    args.find((arg) => arg.startsWith("--ping-interval="))?.split("=")[1] ?? "60",
    10,
  );
  const idleThreshold = parseInt(
    args.find((arg) => arg.startsWith("--idle-threshold="))?.split("=")[1] ?? "3",
    10,
  );
  const agentId = args.find((arg) => arg.startsWith("--agent-id="))?.split("=")[1] ?? "default";

  const monitor = new ClaudeCodeActivityMonitor({
    checkIntervalMs: checkInterval * 1000,
    pingIntervalMs: pingInterval * 1000,
    idleThresholdMinutes: idleThreshold,
    agentId,
    dryRun,
    verbose,
  });

  // Handle graceful shutdown
  const shutdown = () => {
    console.log("\nShutting down activity monitor...");
    monitor.stop();
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  monitor.start();

  // Keep process alive
  await new Promise(() => {});
}

// Run if called directly
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error("Fatal error:", err);
    process.exit(1);
  });
}

export default ClaudeCodeActivityMonitor;
