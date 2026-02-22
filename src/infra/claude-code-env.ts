/**
 * Detect whether the current process is running inside a Claude Code session.
 *
 * Used to auto-enable session keep-alive hooks without requiring explicit config.
 */
export function isClaudeCodeSession(): boolean {
  return !!(
    process.env.CLAUDECODE ||
    process.env.CLAUDE_CODE_SESSION_ID ||
    process.env.CLAUDE_CODE_REMOTE_SESSION_ID
  );
}
