#!/usr/bin/env node
/**
 * PreToolUse guard: block a file edit that targets the MAIN checkout while the
 * session is working inside an agent-env worktree (cwd under
 * `<repo>/.claude/worktrees/<name>/`).
 *
 * Why this exists
 * ---------------
 * Absolute file paths captured during planning (Read before `EnterWorktree`)
 * point at the MAIN checkout. `EnterWorktree` moves the session cwd into the
 * worktree, but it does NOT rewrite absolute paths — so a subsequent Edit/Write
 * that reuses one of those paths writes to the main checkout. Because a worktree
 * mirrors the main tree, that path exists and the write SUCCEEDS silently: tests
 * run in the worktree then validate unchanged code, and the real changes sit on
 * the wrong branch. This guard catches the mistake at the moment it happens and
 * tells the agent the correct worktree path to use instead.
 *
 * Scope
 * -----
 * - Active ONLY when cwd is inside `.../.claude/worktrees/<name>/` (i.e. an
 *   EnterWorktree session). Normal main-checkout sessions are unaffected.
 * - Blocks edits to the main checkout's working tree (paths under <repo> but
 *   not under <repo>/.claude/). Edits to the worktree itself, to other parts of
 *   .claude/, and to anything outside the repo are allowed.
 *
 * Fails OPEN: any malformed input or unexpected error exits 0 (allow). It only
 * ever emits a blocking exit 2 for a confirmed main-checkout edit from a
 * worktree session — never break editing because the guard itself stumbled.
 *
 * Canonical source lives in the agent-environments skill assets; wired into
 * ~/.claude/settings.json as a PreToolUse hook on Edit|Write|MultiEdit|NotebookEdit.
 */
const path = require("path");
const fs = require("fs");

try {
  let raw = "";
  try {
    raw = fs.readFileSync(0, "utf8");
  } catch {
    process.exit(0);
  }
  if (!raw.trim()) process.exit(0);

  const data = JSON.parse(raw);

  const EDIT_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"]);
  if (!EDIT_TOOLS.has(data.tool_name)) process.exit(0);

  const cwd = data.cwd || process.cwd();
  const marker = "/.claude/worktrees/";
  const idx = cwd.indexOf(marker);
  if (idx === -1) process.exit(0); // not a worktree session — nothing to guard

  const input = data.tool_input || {};
  const fp = input.file_path || input.notebook_path;
  if (!fp || typeof fp !== "string") process.exit(0);

  const mainRoot = cwd.slice(0, idx);
  const abs = path.resolve(cwd, fp);

  const underMain = abs === mainRoot || abs.startsWith(mainRoot + path.sep);
  const underClaude = abs.startsWith(mainRoot + path.sep + ".claude" + path.sep);
  // Allow: outside the repo entirely, or under <repo>/.claude/ (the worktree
  // itself, settings, tooling). Block: the main checkout's working tree.
  if (!underMain || underClaude) process.exit(0);

  const name = cwd.slice(idx + marker.length).split(path.sep)[0];
  const worktreeRoot = mainRoot + marker + name;
  const rel = abs.slice(mainRoot.length + 1);
  const suggested = path.join(worktreeRoot, rel);

  process.stderr.write(
    `Blocked by worktree-edit-guard: this ${data.tool_name} targets the MAIN ` +
      `checkout while you are working in the agent-env worktree '${name}'.\n` +
      `  target: ${abs}\n` +
      `Edits to a main-checkout path from a worktree session silently hit the ` +
      `wrong copy (the worktree mirrors the tree, so no error surfaces, and the ` +
      `worktree's tests then validate unchanged code). Re-issue the edit against ` +
      `the worktree path:\n` +
      `  ${suggested}\n`
  );
  process.exit(2);
} catch {
  process.exit(0); // fail open
}
