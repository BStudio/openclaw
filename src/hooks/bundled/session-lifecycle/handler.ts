/**
 * Session lifecycle hook — Claude Code container keep-alive
 *
 * Keeps Claude Code container sessions alive by detecting OpenClaw agent activity.
 * Runs as an in-process timer on gateway:startup (no separate process needed).
 *
 * Only activates in Claude Code sessions (detected via CLAUDECODE env var).
 */

import type { OpenClawConfig } from "../../../config/config.js";
import type { HookHandler } from "../../hooks.js";
import { resolveStorePath } from "../../../config/sessions/paths.js";
import { loadSessionStore } from "../../../config/sessions/store.js";
import { getActiveTaskCount, getTotalQueueSize } from "../../../process/command-queue.js";

const LOG_FILE = "/tmp/claude-code-activity-monitor.log";
const CHECK_INTERVAL_MS = 30_000; // 30 seconds
const PING_INTERVAL_MS = 60_000; // 60 seconds
const IDLE_THRESHOLD_MS = 10 * 60_000; // 10 minutes

let activityTimer: ReturnType<typeof setInterval> | null = null;
let lastPingTime = 0;

function logToFile(message: string): void {
  try {
    const fs = require("node:fs");
    fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] ${message}\n`);
  } catch {
    // silently fail
  }
}

function checkAndPing(cfg: OpenClawConfig): void {
  try {
    const now = Date.now();

    // Signal 1: command queue — catches in-flight LLM calls & tool execution
    // that don't update the session store until completion.
    const activeTasks = getActiveTaskCount();
    const totalQueued = getTotalQueueSize();
    const queueBusy = activeTasks > 0 || totalQueued > 0;

    // Signal 2: session store — catches recently-active sessions.
    let activeSessionCount = 0;
    try {
      const storePath = resolveStorePath(cfg.session?.store);
      const store = loadSessionStore(storePath, { skipCache: true });
      const cutoff = now - IDLE_THRESHOLD_MS;

      for (const key of Object.keys(store)) {
        const entry = store[key];
        if (entry?.updatedAt && entry.updatedAt >= cutoff) {
          activeSessionCount++;
        }
      }
    } catch {
      // Session store may be unavailable; rely on queue signal alone.
    }

    const isActive = queueBusy || activeSessionCount > 0;

    if (isActive && now - lastPingTime >= PING_INTERVAL_MS) {
      const ts = new Date().toISOString();
      const parts: string[] = [];
      if (activeSessionCount > 0) {
        parts.push(`${activeSessionCount} session${activeSessionCount !== 1 ? "s" : ""}`);
      }
      if (queueBusy) {
        parts.push(`${activeTasks} running, ${totalQueued} queued`);
      }
      process.stdout.write(`[openclaw-keepalive] ${ts} (${parts.join(", ")})\n`);
      lastPingTime = now;
      logToFile(`ping: ${parts.join(", ")}`);
    }
  } catch (err) {
    logToFile(`check error: ${String(err)}`);
  }
}

const handler: HookHandler = async (event) => {
  if (event.type !== "gateway" || event.action !== "startup") {
    return;
  }

  // Only activate in Claude Code sessions
  const isClaudeCode = process.env.CLAUDECODE || process.env.CLAUDE_CODE_SESSION_ID || false;

  if (!isClaudeCode) {
    logToFile("skipped: not a Claude Code session");
    return;
  }

  // Don't start twice
  if (activityTimer) {
    logToFile("skipped: already running");
    return;
  }

  const ctx = event.context as { cfg?: OpenClawConfig } | undefined;
  const cfg = ctx?.cfg;
  if (!cfg) {
    logToFile("skipped: no config in hook context");
    return;
  }

  logToFile("starting activity monitor");

  activityTimer = setInterval(() => checkAndPing(cfg), CHECK_INTERVAL_MS);
  activityTimer.unref(); // don't block gateway shutdown

  // Do an initial check immediately
  checkAndPing(cfg);
};

export default handler;
