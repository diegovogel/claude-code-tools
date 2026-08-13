#!/usr/bin/env node
/**
 * PreToolUse guard: block a file edit that targets the MAIN checkout while the
 * session is working inside a linked git worktree.
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
 * How a worktree is detected
 * --------------------------
 * Structurally, via git's own on-disk layout — NOT by matching a path substring.
 * A linked worktree's `.git` is a FILE containing `gitdir: <main>/.git/worktrees/<name>`,
 * while a main working tree's `.git` is a directory. That one fact yields both
 * roots: the worktree root is where the `.git` file lives, and the main checkout
 * is the path before `/.git/worktrees/`.
 *
 * This matters because worktrees do not all live in one place. The generic engine
 * puts them under `<repo>/.claude/worktrees/<name>`, but the WordPress flow puts
 * them at `<ENV_PARENT>/<site>__<name>/wp-content/{themes,plugins}/<repo>`, where
 * ENV_PARENT is per-project config. An earlier version of this guard keyed on the
 * literal `/.claude/worktrees/` and was therefore a permanent no-op for every
 * WordPress env — exactly where the silent-wrong-copy bug is hardest to spot,
 * since a WP theme repo usually has no test suite and a misdirected edit just
 * looks like a stale asset cache. Reading git's layout covers every location,
 * including hand-made worktrees and any future ENV_PARENT.
 *
 * Scope
 * -----
 * - Active ONLY when cwd is inside a linked worktree. Main-checkout sessions
 *   exit immediately (the `.git` directory check), so they are unaffected.
 * - Blocks edits to the main checkout's working tree. Edits to the worktree
 *   itself, to anything under <main>/.claude/, and to anything outside the main
 *   checkout (including the rest of a WordPress install around the worktree) are
 *   allowed.
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

// Walk up from `startDir` to the nearest `.git`. Returns the directory holding
// it plus whether it is a file (linked worktree) or a directory (main checkout).
function findGitEntry(startDir) {
  let dir = path.resolve(startDir);
  for (;;) {
    const candidate = path.join(dir, ".git");
    try {
      const st = fs.statSync(candidate);
      return { root: dir, gitPath: candidate, isFile: st.isFile() };
    } catch {
      // Not here (or unreadable) — keep walking up.
    }
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

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

  const entry = findGitEntry(cwd);
  if (!entry) process.exit(0); // not in a git repo at all
  if (!entry.isFile) process.exit(0); // main working tree — nothing to guard

  const worktreeRoot = entry.root;

  let gitdir;
  try {
    const m = fs.readFileSync(entry.gitPath, "utf8").match(/^\s*gitdir:\s*(.+?)\s*$/m);
    if (!m) process.exit(0);
    gitdir = path.resolve(worktreeRoot, m[1]); // absolute in practice; resolve covers relative
  } catch {
    process.exit(0);
  }

  // Linked worktree: <main>/.git/worktrees/<name>. A submodule's .git file points
  // at <super>/.git/modules/<name> instead, so it correctly falls through here.
  const marker = path.sep + ".git" + path.sep + "worktrees" + path.sep;
  const idx = gitdir.indexOf(marker);
  if (idx === -1) process.exit(0);

  const mainRoot = gitdir.slice(0, idx);
  const name = gitdir.slice(idx + marker.length).split(path.sep)[0];

  const input = data.tool_input || {};
  const fp = input.file_path || input.notebook_path;
  if (!fp || typeof fp !== "string") process.exit(0);

  const abs = path.resolve(cwd, fp);

  const underMain = abs === mainRoot || abs.startsWith(mainRoot + path.sep);
  const underWorktree = abs === worktreeRoot || abs.startsWith(worktreeRoot + path.sep);
  const underClaude = abs.startsWith(mainRoot + path.sep + ".claude" + path.sep);
  // Allow: outside the main checkout entirely (including the surrounding
  // WordPress install), the worktree itself (which the generic engine nests
  // inside the main checkout), and <main>/.claude/ tooling and settings.
  if (!underMain || underWorktree || underClaude) process.exit(0);

  const suggested = path.join(worktreeRoot, path.relative(mainRoot, abs));

  process.stderr.write(
    `Blocked by worktree-edit-guard: this ${data.tool_name} targets the MAIN ` +
      `checkout while you are working in the agent-env worktree '${name}'.\n` +
      `  target:   ${abs}\n` +
      `  worktree: ${worktreeRoot}\n` +
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
