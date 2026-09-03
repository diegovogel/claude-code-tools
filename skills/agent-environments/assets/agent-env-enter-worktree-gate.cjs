#!/usr/bin/env node
/**
 * PreToolUse guard on EnterWorktree: refuse to bind the session to a worktree
 * that lives inside a WordPress agent env.
 *
 * Why: EnterWorktree switches on the runtime's worktree isolation, which refuses
 * the command shapes ordinary work needs (any git at a main checkout, command
 * substitution, heredocs with braces, chained git) and stays on across
 * compaction and app restarts while leaving no trace in the session's context. The WordPress flow moves the session with the desktop app's
 * change_directory tool instead, which binds nothing. Standard envs under
 * .claude/worktrees are not affected. To bind anyway, set
 * AGENT_ENV_ALLOW_ENTERWORKTREE=1 (the "env" block of ~/.claude/settings.json).
 *
 * Wired in ~/.claude/settings.json as a PreToolUse hook with matcher
 * "EnterWorktree". Fails open: any error exits 0.
 */
const fs = require("fs");
const path = require("path");

function real(p) { try { return fs.realpathSync(p); } catch { return path.resolve(p); } }
// The env install: nearest ancestor holding wp-config.php whose name is <site>__<env>.
function findInstall(start) {
  let d = real(start);
  for (;;) {
    if (path.basename(d).includes("__") && fs.existsSync(path.join(d, "wp-config.php"))) return d;
    const parent = path.dirname(d);
    if (parent === d) return null;
    d = parent;
  }
}

try {
  const raw = fs.readFileSync(0, "utf8");
  if (!raw.trim()) process.exit(0);
  const data = JSON.parse(raw);
  if (data.tool_name !== "EnterWorktree") process.exit(0);
  if (process.env.AGENT_ENV_ALLOW_ENTERWORKTREE === "1") process.exit(0);
  const target = String((data.tool_input || {}).path || "");
  if (!target) process.exit(0); // `name`: a new worktree under .claude/worktrees
  const cwd = data.cwd || process.cwd();
  const abs = path.isAbsolute(target) ? target : path.resolve(cwd, target);
  const install = findInstall(abs);
  if (!install) process.exit(0);
  const name = install.slice(install.lastIndexOf("__") + 2);
  const reason =
    `Blocked by agent-env-enter-worktree-gate: ${abs} is inside WordPress agent env '${name}' (${install}). ` +
    `Binding the session to it with EnterWorktree turns on the runtime's worktree isolation, which refuses the ` +
    `command shapes ordinary work needs (git at a main checkout, command substitution, heredocs with braces, chained ` +
    `git) and stays on invisibly across compaction and app restarts. Move the session ` +
    `there without binding instead: call mcp__ccd_directory__change_directory with path ${abs} (takes effect at the ` +
    `end of the turn; one folder approval). To bind anyway, set AGENT_ENV_ALLOW_ENTERWORKTREE=1 in the "env" block ` +
    `of ~/.claude/settings.json.`;
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
  }));
  process.exit(0);
} catch {
  process.exit(0);
}
