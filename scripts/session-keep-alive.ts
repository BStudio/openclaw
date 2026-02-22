#!/usr/bin/env node --import tsx
/**
 * DEPRECATED: Use the bundled session-lifecycle hook instead.
 * See src/hooks/bundled/session-lifecycle/handler.ts
 * The in-process hook posts to the session ingress API and monitors the
 * command queue directly — this service is kept for reference only.
 *
 * Session Keep-Alive Service
 *
 * Prevents active sessions from timing out by periodically updating their updatedAt timestamp.
 * Unlike heartbeats (which explicitly restore updatedAt to allow idle expiry), this service
 * keeps sessions alive as long as they show recent activity.
 *
 * This is useful for:
 * - Web sessions that should stay alive during active work
 * - Long-running tasks where the agent is working but not generating user-visible output
 * - Preventing session expiry during periods of active tool use
 */

import { loadConfig } from "../src/config/config.js";
import { loadSessionStore, resolveStorePath, saveSessionStore } from "../src/config/sessions.js";
import { createSubsystemLogger } from "../src/logging/subsystem.js";

const log = createSubsystemLogger("session-keep-alive");

type KeepAliveOptions = {
  /** Interval between keep-alive checks (milliseconds) */
  intervalMs?: number;
  /** Only keep alive sessions with activity within this many minutes */
  activityThresholdMinutes?: number;
  /** Agent ID to monitor (defaults to default agent) */
  agentId?: string;
  /** Dry run mode (don't actually update sessions) */
  dryRun?: boolean;
};

const DEFAULT_INTERVAL_MS = 60_000; // 1 minute
const DEFAULT_ACTIVITY_THRESHOLD_MINUTES = 10; // 10 minutes

export class SessionKeepAlive {
  private timer: NodeJS.Timeout | null = null;
  private stopped = false;
  private readonly options: Required<KeepAliveOptions>;

  constructor(options: KeepAliveOptions = {}) {
    this.options = {
      intervalMs: options.intervalMs ?? DEFAULT_INTERVAL_MS,
      activityThresholdMinutes:
        options.activityThresholdMinutes ?? DEFAULT_ACTIVITY_THRESHOLD_MINUTES,
      agentId: options.agentId ?? "default",
      dryRun: options.dryRun ?? false,
    };
  }

  start(): void {
    if (this.timer) {
      log.warn("Session keep-alive already running");
      return;
    }

    log.info("Starting session keep-alive service", {
      intervalMs: this.options.intervalMs,
      activityThresholdMinutes: this.options.activityThresholdMinutes,
      agentId: this.options.agentId,
      dryRun: this.options.dryRun,
    });

    this.scheduleNext();
  }

  stop(): void {
    if (this.stopped) {
      return;
    }

    this.stopped = true;

    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }

    log.info("Session keep-alive service stopped");
  }

  private scheduleNext(): void {
    if (this.stopped) {
      return;
    }

    this.timer = setTimeout(async () => {
      this.timer = null;

      try {
        await this.runKeepAlive();
      } catch (err) {
        log.error("Keep-alive run failed", { error: String(err) });
      }

      this.scheduleNext();
    }, this.options.intervalMs);

    this.timer.unref?.();
  }

  private async runKeepAlive(): Promise<void> {
    const now = Date.now();
    const cfg = loadConfig();
    const storePath = resolveStorePath(cfg.session?.store, { agentId: this.options.agentId });

    // Load session store
    const store = loadSessionStore(storePath);
    const sessionKeys = Object.keys(store);

    if (sessionKeys.length === 0) {
      log.debug("No sessions found");
      return;
    }

    // Filter to recently active sessions
    const activityThresholdMs = this.options.activityThresholdMinutes * 60_000;
    const cutoffTime = now - activityThresholdMs;

    const activeSessions = sessionKeys.filter((key) => {
      const entry = store[key];
      if (!entry) {
        return false;
      }

      const updatedAt = entry.updatedAt ?? 0;
      return updatedAt >= cutoffTime;
    });

    if (activeSessions.length === 0) {
      log.debug("No recently active sessions found");
      return;
    }

    log.info(`Found ${activeSessions.length} active session(s) to keep alive`);

    // Update timestamps for active sessions
    for (const sessionKey of activeSessions) {
      const entry = store[sessionKey];
      if (!entry) {
        continue;
      }

      const previousUpdatedAt = entry.updatedAt ?? 0;
      const ageMinutes = Math.floor((now - previousUpdatedAt) / 60_000);

      if (this.options.dryRun) {
        log.info(`[DRY RUN] Would keep alive session: ${sessionKey} (age: ${ageMinutes}m)`);
      } else {
        // Update the timestamp to prevent idle expiry
        store[sessionKey] = {
          ...entry,
          updatedAt: now,
        };

        log.debug(`Kept alive session: ${sessionKey} (age: ${ageMinutes}m)`);
      }
    }

    // Save updated store (unless dry run)
    if (!this.options.dryRun && activeSessions.length > 0) {
      await saveSessionStore(storePath, store);
      log.info(`Updated ${activeSessions.length} session timestamp(s)`);
    }
  }
}

// CLI entry point
async function main() {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const intervalSeconds = parseInt(
    args.find((arg) => arg.startsWith("--interval="))?.split("=")[1] ?? "60",
    10,
  );
  const intervalMs = intervalSeconds * 1000;
  const activityMinutes = parseInt(
    args.find((arg) => arg.startsWith("--activity-threshold="))?.split("=")[1] ?? "10",
    10,
  );

  if (args.includes("--help") || args.includes("-h")) {
    console.log(`
Session Keep-Alive Service

Prevents active sessions from timing out by periodically updating their timestamps.

Usage:
  tsx scripts/session-keep-alive.ts [options]

Options:
  --interval=SECONDS            Check interval in seconds (default: 60)
  --activity-threshold=MINUTES  Only keep alive sessions active within N minutes (default: 10)
  --dry-run                     Show what would be updated without making changes
  --help, -h                    Show this help message

Examples:
  # Run with defaults (check every 60s, keep alive sessions active in last 10m)
  tsx scripts/session-keep-alive.ts

  # Check every 30 seconds
  tsx scripts/session-keep-alive.ts --interval=30

  # Keep alive sessions active in last 5 minutes
  tsx scripts/session-keep-alive.ts --activity-threshold=5

  # Dry run to see what would be updated
  tsx scripts/session-keep-alive.ts --dry-run
    `);
    process.exit(0);
  }

  const keepAlive = new SessionKeepAlive({
    intervalMs,
    activityThresholdMinutes: activityMinutes,
    dryRun,
  });

  // Handle graceful shutdown
  const shutdown = () => {
    console.log("\nShutting down...");
    keepAlive.stop();
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  keepAlive.start();

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

export default SessionKeepAlive;
