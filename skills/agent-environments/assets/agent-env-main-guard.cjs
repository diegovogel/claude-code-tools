#!/usr/bin/env node
/**
 * PreToolUse guard on Bash: while the session's working directory is inside a
 * WordPress agent env, refuse commands that mutate one of the MAIN checkouts the
 * env's worktrees link back to. PROTOTYPE, 2026-09-02.
 *
 * Why: the runtime's own isolation protects only the repository the session was
 * launched from (and the main checkout of a worktree it is bound to). It never
 * covers the sibling repo (the plugin's main checkout next to a theme env), and
 * it covers nothing at all when the session is not bound. This is the path-based
 * net for both cases. It is a tripwire, not shape analysis: it matches literal
 * main-checkout paths on the command line.
 *
 * Main checkouts are derived from git, not from a marker: every repo under the
 * env's wp-content whose `.git` is a gitdir pointer resolves to its shared
 * checkout, and every repo under the main install those checkouts sit in is
 * covered too (a sibling the env only snapshotted has no pointer). Read-only
 * git against a main checkout is allowed, and so is `worktree add` into the
 * env; the lifecycle script needs no exemption because its command line never
 * names a main checkout as a mutation target (its body does the git).
 *
 * Fails open: any error exits 0.
 */
const fs = require("fs");
const path = require("path");

function real(p) { try { return fs.realpathSync(p); } catch { return path.resolve(p); } }
function findWpInstall(start, envOnly = false) {
  let d = real(start);
  for (;;) {
    if ((!envOnly || path.basename(d).includes("__")) && fs.existsSync(path.join(d, "wp-config.php"))) return d;
    const parent = path.dirname(d);
    if (parent === d) return null;
    d = parent;
  }
}
function findInstall(start) { return findWpInstall(start, true); }
function mainCheckouts(install) {
  const mains = new Set();
  for (const kind of ["themes", "plugins"]) {
    const base = path.join(install, "wp-content", kind);
    let entries = [];
    try { entries = fs.readdirSync(base); } catch { continue; }
    for (const e of entries) {
      const gitPath = path.join(base, e, ".git");
      let st; try { st = fs.statSync(gitPath); } catch { continue; }
      if (!st.isFile()) continue;
      const txt = fs.readFileSync(gitPath, "utf8");
      const mm = txt.match(/^\s*gitdir:\s*(.+?)\s*$/m);
      if (!mm) continue;
      const gitdir = path.resolve(path.join(base, e), mm[1]);
      const marker = path.sep + ".git" + path.sep + "worktrees" + path.sep;
      const idx = gitdir.indexOf(marker);
      if (idx !== -1) mains.add(real(gitdir.slice(0, idx)));
    }
  }
  const project = process.env.CLAUDE_PROJECT_DIR;
  // After an app restart the project dir can be the env itself (the desktop app
  // relaunches a session where it stood); a snapshot repo there has a real .git
  // directory, and the env is never a main.
  if (project && !underInstall(project, install, project)) {
    try { if (fs.statSync(path.join(project, ".git")).isDirectory()) mains.add(real(project)); } catch {}
  }
  // A repo the env holds only as a CoW snapshot (the default for the sibling
  // plugin) has no pointer to follow, so also list every repo in the MAIN
  // install, found by walking up from any main checkout known so far or from
  // the launch directory.
  const mainInstalls = new Set();
  for (const start of [...mains, project].filter(Boolean)) {
    const wp = findWpInstall(start);
    if (wp && wp !== install) mainInstalls.add(wp);
  }
  for (const wp of mainInstalls) {
    for (const kind of ["themes", "plugins"]) {
      const base = path.join(wp, "wp-content", kind);
      let entries = [];
      try { entries = fs.readdirSync(base); } catch { continue; }
      for (const e of entries) {
        try { if (fs.statSync(path.join(base, e, ".git")).isDirectory()) mains.add(real(path.join(base, e))); } catch {}
      }
    }
  }
  return [...mains];
}
const READ_ONLY_GIT = new Set(["status", "log", "diff", "show", "rev-parse", "rev-list", "ls-files", "ls-remote",
  "describe", "blame", "cat-file", "for-each-ref", "fetch", "shortlog", "grep", "show-ref", "merge-base", "name-rev"]);
function underInstall(p, install, cwd) {
  const r = path.resolve(cwd, p.replace(/^["']|["']$/g, ""));
  return r === install || r.startsWith(install + path.sep) || real(r).startsWith(install + path.sep);
}
function isReadOnlyGit(args, install, cwd) {
  const sub = args[0];
  if (!sub) return true;
  if (READ_ONLY_GIT.has(sub)) return true;
  if (sub === "branch") return args.slice(1).every(a => /^(-a|-r|-l|-v|-vv|--list|--show-current|--merged|--no-merged|--contains|--format=.*)$/.test(a));
  // `worktree add` into the env install is the sibling-repo setup (a plugin
  // worktree beside a theme env); on the main checkout it writes only
  // .git/worktrees. `prune` drops stale entries and nothing else.
  if (sub === "worktree") {
    if (args[1] === "list" || args[1] === "prune") return true;
    if (args[1] !== "add") return false;
    // The path is the first positional; -b/-B take the branch name as a value.
    let target = null;
    for (let i = 2; i < args.length; i++) {
      if (args[i] === "-b" || args[i] === "-B") { i++; continue; }
      if (args[i].startsWith("-")) continue;
      target = args[i]; break;
    }
    return target !== null && underInstall(target, install, cwd);
  }
  if (sub === "remote") return args.length === 1 || args[1] === "-v" || args[1] === "show" || args[1] === "get-url";
  if (sub === "config") return args.slice(1).some(a => /^(--get|--get-all|--list|-l|--get-regexp)$/.test(a));
  if (sub === "stash") return args[1] === "list" || args[1] === "show";
  return false;
}
function esc(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }
// Keep a heredoc's operator line and terminator, drop its body: a log entry
// that quotes a denied command must not be denied itself.
function stripHeredocBodies(cmd) {
  return cmd.replace(/(<<-?\s*(["']?)(\w+)\2[^\n]*\n)[\s\S]*?\n[ \t]*\3(?=\n|$)/g, "$1$3");
}

try {
  const raw = fs.readFileSync(0, "utf8");
  if (!raw.trim()) process.exit(0);
  const data = JSON.parse(raw);
  if (data.tool_name !== "Bash") process.exit(0);
  // A backslash-newline continues the same command; a bare newline ends it, and
  // the per-command scans below stop at a newline for that reason. Heredoc
  // bodies go first so a continuation inside one cannot glue lines together.
  const cmd = stripHeredocBodies(String((data.tool_input || {}).command || "")).replace(/\\\n/g, " ");
  const cwd = data.cwd || process.cwd();
  const install = findInstall(cwd);
  if (!install) process.exit(0);
  const envName = install.slice(install.lastIndexOf("__") + 2);
  const mains = mainCheckouts(install);
  // Destroying the env the shell stands in: the script refuses that itself, but
  // an env's in-tree copy of the script is whatever its branch last committed,
  // and a session bound by EnterWorktree cannot run the main checkout's copy.
  // Matched anywhere on the line on purpose (quoted paths, VAR= and nohup
  // prefixes, `bash -c`): a mention in an echo is a cheap false positive for a
  // tripwire, while a missed spelling is the exact hazard.
  const destroy = cmd.match(/agent-env(?:-wp)?\.sh["']?\s+destroy\s+["']?([A-Za-z0-9._-]+)/);
  if (destroy && destroy[1] === envName) {
    const owner = mains.find(m => fs.existsSync(path.join(m, ".agent-env", "wp", envName, "meta.env"))) || mains[0] || "<the main checkout that created it>";
    deny(`Blocked by agent-env-main-guard: destroy of '${envName}' while the shell's working directory is inside that env (${install}); ` +
      `destroy deletes it. Move the session's working directory to ${owner} first (desktop app: change_directory; after ` +
      `EnterWorktree: ExitWorktree with action keep), then rerun: ${owner}/scripts/agent-env-wp.sh destroy ${envName}`);
  }
  if (!mains.length) process.exit(0);

  let hit = null;
  for (const M of mains) {
    const P = `["']?${esc(M)}(?:/[^\\s"']*)?["']?`;
    if (new RegExp(`(?:^|[;&|(]\\s*|\\s)cd\\s+${P}(?:\\s|$|[;&|)])`).test(cmd)) { hit = `cd into ${M}`; break; }
    if (new RegExp(`GIT_DIR=${P}|--git-dir=${P}|--work-tree=${P}`).test(cmd)) { hit = `git redirected into ${M}`; break; }
    const gitC = new RegExp(`git\\s+-C\\s+${P}\\s+([^;&|\\n]*)`, "g");
    let g; let bad = false;
    while ((g = gitC.exec(cmd))) {
      const args = g[1].trim().split(/\s+/).filter(Boolean);
      if (!isReadOnlyGit(args, install, cwd)) { bad = true; break; }
    }
    if (bad) { hit = `mutating git against ${M}`; break; }
    if (new RegExp(`(?:^|[;&|(]\\s*|\\s)(?:rm|rmdir)\\s+[^;&|\\n]*${P}`).test(cmd)) { hit = `rm touching ${M}`; break; }
    // cp/mv: only the DESTINATION matters; copying FROM a main checkout into the env is routine.
    const mvcp = new RegExp(`(?:^|[;&|(]\\s*|\\s)(?:cp|mv)\\s+([^;&|\\n]*)`, "g");
    let mc; let badDest = false;
    while ((mc = mvcp.exec(cmd))) {
      const args = mc[1].trim().split(/\s+/).filter(a => a && !a.startsWith("-"));
      const dest = args[args.length - 1] || "";
      if (new RegExp(`^${P}$`).test(dest)) { badDest = true; break; }
    }
    if (badDest) { hit = `cp/mv into ${M}`; break; }
    if (new RegExp(`>>?\\s*${P}`).test(cmd)) { hit = `output redirected into ${M}`; break; }
  }
  if (!hit) process.exit(0);
  deny(`Blocked by agent-env-main-guard: ${hit}, while this session's working directory is inside agent env ` +
    `'${envName}' (${install}). An env isolates its repos from the main checkouts; run git in the env's own ` +
    `worktrees, and use the lifecycle script for env operations (${mains[0]}/scripts/agent-env-wp.sh). ` +
    `Read-only git against a main checkout (status, log, diff, worktree list) is allowed, and so is ` +
    `\`worktree add\` of a path inside this env (the sibling-repo setup).`);
} catch {
  process.exit(0);
}

function deny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
  }));
  process.exit(0);
}
