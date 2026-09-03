// Pipe-tests agent-env-enter-worktree-gate.cjs against a synthetic env install.
// Run with `node <this file>`; exits non-zero on any failure. Tests the copy
// of the hook next to this file, not the one wired in settings.
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const gate = path.join(__dirname, "../assets/agent-env-enter-worktree-gate.cjs");
const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "enter-gate-")));
const install = path.join(root, "envs", "site__envx");
const envTheme = path.join(install, "wp-content/themes/t");
const main = path.join(root, "mainsite/wp-content/themes/t");
const standard = path.join(main, ".claude/worktrees/task-a");

function run(input, cwd, extraEnv = {}, rawInput) {
  const e = { ...process.env };
  delete e.AGENT_ENV_ALLOW_ENTERWORKTREE;
  Object.assign(e, extraEnv);
  const r = spawnSync("node", [gate], {
    input: rawInput !== undefined ? rawInput : JSON.stringify({ tool_name: "EnterWorktree", cwd, tool_input: input }),
    env: e, encoding: "utf8",
  });
  return { decision: r.stdout.includes('"deny"') ? "deny" : "allow", status: r.status, stdout: r.stdout, stderr: r.stderr };
}

const cases = [
  // [label, expected, tool_input, cwd, extra env]
  ["absolute path into a WP env", "deny", { path: envTheme }, main, {}],
  ["relative path into a WP env, resolved against cwd", "deny", { path: "envs/site__envx/wp-content/themes/t" }, root, {}],
  ["path deeper inside the env", "deny", { path: path.join(envTheme, "includes") }, main, {}],
  ["standard worktree under .claude/worktrees", "allow", { path: standard }, main, {}],
  ["new worktree by name", "allow", { name: "task-b" }, main, {}],
  ["no input at all", "allow", {}, main, {}],
  ["toggle set: bind anyway", "allow", { path: envTheme }, main, { AGENT_ENV_ALLOW_ENTERWORKTREE: "1" }],
  ["wp install without the __ marker is not an env", "allow", { path: main }, root, {}],
];

let failures = 0;
function report(ok, label) { if (!ok) failures++; console.log(`${ok ? "ok  " : "FAIL"} ${label}`); }

try {
  for (const d of [envTheme, standard]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(install, "wp-config.php"), "<?php\n");
  fs.writeFileSync(path.join(root, "mainsite/wp-config.php"), "<?php\n");
  for (const [label, expected, input, cwd, extraEnv] of cases) {
    const r = run(input, cwd, extraEnv);
    report(r.decision === expected && r.status === 0 && r.stderr === "", `expected=${expected} got=${r.decision} status=${r.status}${r.stderr ? " stderr!" : ""}  ${label}`);
  }
  {
    const r = run({ path: envTheme }, main);
    report(r.stdout.includes("mcp__ccd_directory__change_directory") && r.stdout.includes(envTheme), "denial names change_directory and the path");
  }
  for (const [label, raw] of [["other tool", JSON.stringify({ tool_name: "Bash", cwd: main, tool_input: { command: "ls" } })], ["malformed JSON", "{nope"], ["empty stdin", ""]]) {
    const r = run({}, main, {}, raw);
    report(r.decision === "allow" && r.status === 0 && r.stdout === "" && r.stderr === "", `fails open on ${label}`);
  }
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
console.log(failures ? `${failures} FAILED` : "all cases passed");
process.exit(failures ? 1 : 0);
