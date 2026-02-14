#!/usr/bin/env node
/**
 * Auth diagnostic — runs after session-start hook writes auth files.
 * Tests the full auth chain and logs results to /tmp/openclaw-auth-diag.log
 */
import { readFileSync, existsSync } from "fs";
import { join } from "path";

const log = (msg) => {
  const line = `[auth-diag] ${msg}`;
  console.error(line);
};

const TOKEN_FILE = "/home/claude/.claude/remote/.session_ingress_token";
const AGENT_DIR = join(process.env.HOME, ".openclaw/agents/main/agent");
const AUTH_JSON = join(AGENT_DIR, "auth.json");
const AUTH_PROFILES = join(AGENT_DIR, "auth-profiles.json");

// 1. Check token file
log("--- Step 1: Token file ---");
if (existsSync(TOKEN_FILE)) {
  const token = readFileSync(TOKEN_FILE, "utf-8").trim();
  log(`Token file: ${token.length} chars, prefix: ${token.substring(0, 15)}`);
  log(`Contains sk-ant-si-: ${token.includes("sk-ant-si-")}`);
  log(`Contains sk-ant-oat: ${token.includes("sk-ant-oat")}`);
} else {
  log("TOKEN FILE MISSING!");
}

// 2. Check auth files
log("--- Step 2: Auth files ---");
for (const [name, path] of [
  ["auth.json", AUTH_JSON],
  ["auth-profiles.json", AUTH_PROFILES],
]) {
  if (existsSync(path)) {
    try {
      const data = JSON.parse(readFileSync(path, "utf-8"));
      log(`${name}: exists, keys: ${JSON.stringify(Object.keys(data))}`);
      if (name === "auth.json" && data.anthropic) {
        log(`  anthropic.type: ${data.anthropic.type}`);
        log(`  anthropic.access prefix: ${data.anthropic.access?.substring(0, 15)}`);
        log(`  anthropic.expired: ${Date.now() >= (data.anthropic.expires || 0)}`);
      }
    } catch (e) {
      log(`${name}: PARSE ERROR: ${e.message}`);
    }
  } else {
    log(`${name}: MISSING`);
  }
}

// 3. Check env vars
log("--- Step 3: Environment ---");
log(`ANTHROPIC_OAUTH_TOKEN set: ${!!process.env.ANTHROPIC_OAUTH_TOKEN}`);
log(
  `ANTHROPIC_OAUTH_TOKEN prefix: ${process.env.ANTHROPIC_OAUTH_TOKEN?.substring(0, 15) || "N/A"}`,
);
log(`ANTHROPIC_API_KEY set: ${!!process.env.ANTHROPIC_API_KEY}`);
log(`ANTHROPIC_BASE_URL: ${process.env.ANTHROPIC_BASE_URL || "N/A"}`);

// 4. Test actual API call
log("--- Step 4: API call test ---");
const token =
  process.env.ANTHROPIC_OAUTH_TOKEN ||
  (existsSync(TOKEN_FILE) ? readFileSync(TOKEN_FILE, "utf-8").trim() : null);

if (token) {
  const body = JSON.stringify({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 5,
    messages: [{ role: "user", content: "Say ok" }],
  });

  // Test Bearer auth
  try {
    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "claude-code-20250219,oauth-2025-04-20",
      },
      body,
    });
    log(`Bearer auth: ${resp.status} ${resp.ok ? "OK" : "FAIL"}`);
    if (!resp.ok) {
      const err = await resp.text();
      log(`Bearer error: ${err.substring(0, 200)}`);
    }
  } catch (e) {
    log(`Bearer fetch error: ${e.message}`);
  }
} else {
  log("NO TOKEN AVAILABLE - cannot test API call");
}

log("--- Diagnostic complete ---");
