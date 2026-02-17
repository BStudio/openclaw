/**
 * Session lifecycle hook — Claude Code container keep-alive
 *
 * Keeps Claude Code container sessions alive by detecting OpenClaw agent activity.
 * Runs as an in-process timer on gateway:startup (no separate process needed).
 *
 * Only activates in Claude Code sessions (detected via CLAUDECODE env var).
 *
 * Uses the session ingress API to signal activity, since OpenClaw runs as a
 * sibling process to Claude Code and stdout writes don't reach it.
 */

import type { OpenClawConfig } from "../../../config/config.js";
import type { HookHandler } from "../../hooks.js";
import { resolveStorePath } from "../../../config/sessions/paths.js";
import { loadSessionStore } from "../../../config/sessions/store.js";
import { isClaudeCodeSession } from "../../../infra/claude-code-env.js";
import { getActiveTaskCount, getTotalQueueSize } from "../../../process/command-queue.js";

const LOG_FILE = "/tmp/claude-code-activity-monitor.log";
const CHECK_INTERVAL_MS = 30_000; // 30 seconds
const PING_INTERVAL_MS = 60_000; // 60 seconds (min time between pings)
const IDLE_THRESHOLD_MS = 10 * 60_000; // 10 minutes
const LIVENESS_LOG_INTERVAL_MS = 10 * 60_000; // 10 minutes

let activityTimer: ReturnType<typeof setInterval> | null = null;
let lastPingTime = 0;
let lastLivenessLog = 0;

function logToFile(message: string): void {
  try {
    const fs = require("node:fs");
    fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] ${message}\n`);
  } catch {
    // silently fail
  }
}

/**
 * Read the session ingress token from the well-known path.
 */
function readIngressToken(): string | null {
  try {
    const fs = require("node:fs");
    const tokenPath =
      process.env.CLAUDE_SESSION_INGRESS_TOKEN_FILE ||
      "/home/claude/.claude/remote/.session_ingress_token";
    return fs.readFileSync(tokenPath, "utf-8").trim();
  } catch {
    return null;
  }
}

/**
 * Post a keepalive event to the session ingress API.
 * This is what environment-manager / the CCR backend watches for activity.
 */
async function postKeepaliveEvent(
  sessionId: string,
  token: string,
  detail: string,
): Promise<boolean> {
  try {
    const crypto = require("node:crypto");
    const uuid = crypto.randomUUID();
    const ts = new Date().toISOString();

    const body = JSON.stringify({
      events: [
        {
          type: "env_manager_log",
          uuid,
          data: {
            level: "info",
            category: "keepalive",
            content: `openclaw-keepalive: ${detail}`,
            timestamp: ts,
          },
        },
      ],
    });

    const resp = await fetch(
      `https://api.anthropic.com/v2/session_ingress/session/${sessionId}/events`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body,
      },
    );

    return resp.ok;
  } catch {
    return false;
  }
}

function checkAndPing(cfg: OpenClawConfig, sessionId: string): void {
  try {
    const now = Date.now();

    // Signal 1: command queue — catches in-flight LLM calls & tool execution
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

    // Periodic liveness log so we can confirm the monitor is still running
    if (now - lastLivenessLog >= LIVENESS_LOG_INTERVAL_MS) {
      logToFile(
        `liveness: monitor running (active=${isActive}, queue=${activeTasks}/${totalQueued}, sessions=${activeSessionCount})`,
      );
      lastLivenessLog = now;
    }

    if (isActive && now - lastPingTime >= PING_INTERVAL_MS) {
      const parts: string[] = [];
      if (activeSessionCount > 0) {
        parts.push(`${activeSessionCount} session${activeSessionCount !== 1 ? "s" : ""}`);
      }
      if (queueBusy) {
        parts.push(`${activeTasks} running, ${totalQueued} queued`);
      }
      const detail = parts.join(", ");

      // Also write to stdout as a fallback (original behavior)
      const ts = new Date().toISOString();
      process.stdout.write(`[openclaw-keepalive] ${ts} (${detail})\n`);

      // Post to session ingress API — this is what actually prevents timeout
      const token = readIngressToken();
      if (token) {
        void postKeepaliveEvent(sessionId, token, detail).then((ok) => {
          logToFile(ok ? `ping OK (API): ${detail}` : `ping FAILED (API): ${detail}`);
        });
      } else {
        logToFile(`ping (stdout only, no token): ${detail}`);
      }

      lastPingTime = now;
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
  if (!isClaudeCodeSession()) {
    logToFile("skipped: not a Claude Code session");
    return;
  }

  const sessionId = process.env.CLAUDE_CODE_REMOTE_SESSION_ID;
  if (!sessionId) {
    logToFile("skipped: CLAUDE_CODE_REMOTE_SESSION_ID not set (cannot post to ingress API)");
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

  const shortId = sessionId.slice(0, 16);
  logToFile(`starting activity monitor (session: ${sessionId})`);
  console.log(`[session-lifecycle] keep-alive monitor started (session: ${shortId}...)`);

  activityTimer = setInterval(() => checkAndPing(cfg, sessionId), CHECK_INTERVAL_MS);
  activityTimer.unref(); // don't block gateway shutdown

  // Do an initial check immediately
  lastLivenessLog = Date.now();
  checkAndPing(cfg, sessionId);
};

export default handler;
