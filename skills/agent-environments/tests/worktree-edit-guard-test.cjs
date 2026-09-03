// Pipe-tests worktree-edit-guard.cjs against two synthetic layouts: a WordPress
// agent env (theme as a linked worktree, plugin as a CoW snapshot, both mains in
// the main install) and a standard engine worktree under .claude/worktrees/.
// The guard denies with exit 2 and a message on stderr, allows with exit 0.
// Run with `node <this file>`; exits non-zero on any failure.
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const guard = path.join(__dirname, "../assets/worktree-edit-guard.cjs");
const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "edit-guard-")));

const main = path.join(root, "mainsite");
const mainTheme = path.join(main, "wp-content/themes/t");
const mainPlugin = path.join(main, "wp-content/plugins/p");
const env = path.join(root, "envs", "site__envx");
const envTheme = path.join(env, "wp-content/themes/t");
const envPlugin = path.join(env, "wp-content/plugins/p");
const repo = path.join(root, "node-app");
const repoWt = path.join(repo, ".claude/worktrees/task-a");
const otherRepo = path.join(root, "other-app");

function run(cwd, filePath, tool = "Edit", rawInput) {
  const input = rawInput !== undefined ? rawInput : JSON.stringify({ tool_name: tool, cwd, tool_input: { file_path: filePath } });
  const r = spawnSync("node", [guard], { input, encoding: "utf8" });
  return { decision: r.status === 2 ? "deny" : "allow", status: r.status, stderr: r.stderr, stdout: r.stdout };
}

let failures = 0;
function report(ok, label) { if (!ok) failures++; console.log(`${ok ? "ok  " : "FAIL"} ${label}`); }

try {
  for (const d of [mainTheme, mainPlugin, envTheme, envPlugin, path.join(mainTheme, ".claude"), repoWt, otherRepo]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(main, "wp-config.php"), "<?php\n");
  fs.writeFileSync(path.join(env, "wp-config.php"), "<?php\n");
  fs.mkdirSync(path.join(mainTheme, ".git/worktrees/t"), { recursive: true });
  fs.mkdirSync(path.join(mainPlugin, ".git"));
  fs.writeFileSync(path.join(envTheme, ".git"), `gitdir: ${path.join(mainTheme, ".git/worktrees/t")}\n`);
  fs.mkdirSync(path.join(envPlugin, ".git"));
  fs.mkdirSync(path.join(repo, ".git/worktrees/task-a"), { recursive: true });
  fs.writeFileSync(path.join(repoWt, ".git"), `gitdir: ${path.join(repo, ".git/worktrees/task-a")}\n`);
  fs.mkdirSync(path.join(otherRepo, ".git"));

  const cases = [
    // [label, expected, cwd, file_path]
    ["WP env: edit to this repo's main checkout", "deny", envTheme, `${mainTheme}/functions.php`],
    ["WP env: edit to the SIBLING's main checkout", "deny", envTheme, `${mainPlugin}/plugin.php`],
    ["WP env: write to the sibling main by relative path", "deny", envTheme, path.relative(envTheme, `${mainPlugin}/plugin.php`)],
    ["WP env: edit inside the worktree", "allow", envTheme, `${envTheme}/functions.php`],
    ["WP env: edit inside the env's plugin snapshot", "allow", envTheme, `${envPlugin}/plugin.php`],
    ["WP env: edit to the env's wp-config", "allow", envTheme, `${env}/wp-config.php`],
    ["WP env: main install's own wp-config is not a repo", "allow", envTheme, `${main}/wp-config.php`],
    ["WP env: <main>/.claude tooling stays editable", "allow", envTheme, `${mainTheme}/.claude/settings.local.json`],
    ["WP env: from inside the snapshot plugin nothing is a worktree", "allow", envPlugin, `${mainTheme}/functions.php`],
    ["standard worktree: edit to its main checkout", "deny", repoWt, `${repo}/src/a.js`],
    ["standard worktree: edit inside the worktree", "allow", repoWt, `${repoWt}/src/a.js`],
    ["standard worktree: an unrelated repo is not a main", "allow", repoWt, `${otherRepo}/src/a.js`],
    ["main checkout session: nothing to guard", "allow", mainTheme, `${mainPlugin}/plugin.php`],
  ];
  for (const [label, expected, cwd, fp] of cases) {
    const r = run(cwd, fp);
    report(r.decision === expected && (expected === "allow" ? r.status === 0 && r.stderr === "" : r.stderr.includes("Blocked by worktree-edit-guard")), `expected=${expected} got=${r.decision} status=${r.status}  ${label}`);
  }
  {
    const r = run(envTheme, `${mainPlugin}/inc/x.php`);
    report(r.stderr.includes(`${envPlugin}/inc/x.php`), "sibling denial suggests the env's copy of the sibling path");
  }
  for (const tool of ["Write", "MultiEdit"]) {
    report(run(envTheme, `${mainPlugin}/plugin.php`, tool).decision === "deny", `${tool} is guarded too`);
  }
  for (const [label, raw] of [["non-edit tool", JSON.stringify({ tool_name: "Bash", cwd: envTheme, tool_input: { command: "ls" } })], ["malformed JSON", "{nope"], ["empty stdin", ""]]) {
    const r = run(envTheme, "", "Edit", raw);
    report(r.status === 0 && r.stderr === "" && r.stdout === "", `fails open on ${label}`);
  }
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
console.log(failures ? `${failures} FAILED` : "all cases passed");
process.exit(failures ? 1 : 0);
