// Pipe-tests agent-env-main-guard.cjs against synthetic install pairs: a main
// install (theme + plugin checkouts) and two envs laid out the way
// agent-env-wp.sh lays them out: envx has the theme as a linked worktree
// (gitdir pointer) and the plugin as a CoW snapshot (a real .git directory),
// envy has both as linked worktrees (the SIBLING_REPOS shape). Run with
// `node <this file>`; exits non-zero on any failure. The command lines below
// would trip the live hook if typed on a Bash command line, which is why they
// live in a script. Tests the copy of the hook next to this file.
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const guard = path.join(__dirname, "../assets/agent-env-main-guard.cjs");
// Canonical path: the guard matches realpath forms, and macOS puts os.tmpdir() behind a symlink.
const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "main-guard-")));

const main = path.join(root, "mainsite");
const mainTheme = path.join(main, "wp-content/themes/t");
const mainPlugin = path.join(main, "wp-content/plugins/p");
const envx = path.join(root, "envs", "site__envx");
const envTheme = path.join(envx, "wp-content/themes/t");
const envPlugin = path.join(envx, "wp-content/plugins/p");
const envy = path.join(root, "envs", "site__envy");
const envyTheme = path.join(envy, "wp-content/themes/t");
const envyPlugin = path.join(envy, "wp-content/plugins/p");

function buildFixture() {
  for (const d of [mainTheme, mainPlugin, path.join(main, "wp-content/plugins/third"), envTheme, envPlugin, envyTheme, envyPlugin]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(main, "wp-config.php"), "<?php\n");
  fs.writeFileSync(path.join(envx, "wp-config.php"), "<?php\n");
  fs.writeFileSync(path.join(envy, "wp-config.php"), "<?php\n");
  // git names a worktree's admin dir after the worktree's basename.
  fs.mkdirSync(path.join(mainTheme, ".git/worktrees/t"), { recursive: true });
  fs.mkdirSync(path.join(mainTheme, ".git/worktrees/t1"), { recursive: true });
  fs.mkdirSync(path.join(mainPlugin, ".git/worktrees/p"), { recursive: true });
  fs.writeFileSync(path.join(envTheme, ".git"), `gitdir: ${path.join(mainTheme, ".git/worktrees/t")}\n`);
  fs.mkdirSync(path.join(envPlugin, ".git"));
  fs.writeFileSync(path.join(envyTheme, ".git"), `gitdir: ${path.join(mainTheme, ".git/worktrees/t1")}\n`);
  fs.writeFileSync(path.join(envyPlugin, ".git"), `gitdir: ${path.join(mainPlugin, ".git/worktrees/p")}\n`);
  // The registry the script writes: <creating repo>/.agent-env/wp/<name>/meta.env.
  for (const name of ["envx", "envy"]) {
    fs.mkdirSync(path.join(mainTheme, ".agent-env/wp", name), { recursive: true });
    fs.writeFileSync(path.join(mainTheme, ".agent-env/wp", name, "meta.env"), `AGENT_ENV_NAME=${name}\n`);
  }
}

function run(cwd, project, command, rawInput) {
  const input = rawInput !== undefined ? rawInput : JSON.stringify({ tool_name: "Bash", cwd, tool_input: { command } });
  const e = { ...process.env };
  delete e.CLAUDE_PROJECT_DIR;
  if (project) e.CLAUDE_PROJECT_DIR = project;
  const r = spawnSync("node", [guard], { input, env: e, encoding: "utf8" });
  let reason = "";
  try { reason = JSON.parse(r.stdout).hookSpecificOutput.permissionDecisionReason; } catch {}
  return { decision: r.stdout.includes('"deny"') ? "deny" : "allow", status: r.status, stderr: r.stderr, stdout: r.stdout, reason };
}

const cases = [
  // [label, expected, cwd, CLAUDE_PROJECT_DIR, command]
  ["snapshot plugin main: commit via -C", "deny", envTheme, mainTheme, `git -C ${mainPlugin} commit -m x`],
  ["snapshot plugin main: cd", "deny", envTheme, mainTheme, `cd ${mainPlugin} && git pull`],
  ["snapshot plugin main: redirect", "deny", envTheme, mainTheme, `echo hi > ${mainPlugin}/x.php`],
  ["snapshot plugin main: rm", "deny", envTheme, mainTheme, `rm -rf ${mainPlugin}/vendor`],
  ["snapshot plugin main: read-only git", "allow", envTheme, mainTheme, `git -C ${mainPlugin} status`],
  ["snapshot plugin main: copy FROM it", "allow", envTheme, mainTheme, `cp ${mainPlugin}/x.php ./`],
  ["theme main via pointer: commit", "deny", envTheme, mainTheme, `git -C ${mainTheme} commit -m x`],
  ["theme main via pointer: worktree list", "allow", envTheme, mainTheme, `git -C ${mainTheme} worktree list`],
  ["env's own snapshot plugin is not a main", "allow", envTheme, mainTheme, `git -C ${envPlugin} commit -m x`],
  ["non-repo dir in main install is out of scope", "allow", envTheme, mainTheme, `rm -rf ${main}/wp-content/plugins/third`],
  ["lifecycle invocation by main path names no mutation target", "allow", envTheme, mainTheme, `${mainTheme}/scripts/agent-env-wp.sh list`],
  ["lifecycle invocation with an env-var prefix", "allow", envTheme, mainTheme, `WP_ENV_PORT=8892 ${mainTheme}/scripts/agent-env-wp.sh run envx -- npm test`],
  ["copying the script INTO a main is not an invocation", "deny", envTheme, mainTheme, `cp scripts/agent-env-wp.sh ${mainTheme}/scripts/agent-env-wp.sh`],
  ["commit message naming the script is not an invocation", "deny", envTheme, mainTheme, `git -C ${mainTheme} commit -m "Regenerate agent-env-wp.sh"`],
  ["sibling setup: worktree add under the env install", "allow", envTheme, mainTheme, `git -C ${mainPlugin} worktree add ${envPlugin} -b worktree-envx`],
  ["sibling setup: quoted path, options first", "allow", envTheme, mainTheme, `git -C ${mainPlugin} worktree add -b worktree-envx "${envPlugin}"`],
  ["sibling setup: relative path resolved against the session cwd", "allow", envTheme, mainTheme, `git -C ${mainPlugin} worktree add ../../plugins/p -b worktree-envx`],
  ["worktree add elsewhere is still a mutation", "deny", envTheme, mainTheme, `git -C ${mainPlugin} worktree add /tmp/elsewhere -b x`],
  ["worktree prune is harmless", "allow", envTheme, mainTheme, `git -C ${mainPlugin} worktree prune`],
  ["worktree remove stays denied", "deny", envTheme, mainTheme, `git -C ${mainPlugin} worktree remove ${envPlugin}`],
  ["project dir is the env theme (after an app restart): mains still derived", "deny", envTheme, envTheme, `git -C ${mainPlugin} commit -m x`],
  ["project dir is the env's snapshot plugin: its own repo is not a main", "allow", envPlugin, envPlugin, `git -C ${envPlugin} commit -m x`],
  ["project dir is the env's snapshot plugin: cd + add in it", "allow", envPlugin, envPlugin, `cd ${envPlugin} && git add .`],
  ["project dir is the env's snapshot plugin: mains still derived", "deny", envPlugin, envPlugin, `git -C ${mainPlugin} commit -m x`],
  ["no project dir at all: mains still derived", "deny", envTheme, "", `git -C ${mainPlugin} commit -m x`],
  ["cwd in env plugin snapshot: theme main derived from sibling pointer", "deny", envPlugin, mainTheme, `git -C ${mainTheme} commit -m x`],
  ["two worktrees (SIBLING_REPOS): plugin main denied from the theme worktree", "deny", envyTheme, mainTheme, `git -C ${mainPlugin} commit -m x`],
  ["two worktrees: theme main denied from the plugin worktree", "deny", envyPlugin, mainTheme, `git -C ${mainTheme} commit -m x`],
  ["two worktrees: the env's own plugin worktree is not a main", "allow", envyTheme, mainTheme, `git -C ${envyPlugin} commit -m x`],
  ["outside any env: silent", "allow", mainTheme, mainTheme, `git -C ${mainPlugin} commit -m x`],
  ["heredoc body quoting rm of a main", "allow", envTheme, mainTheme, `cat >> log.md <<'EOF'\n- \`rm -rf ${mainPlugin}\` -> denied\nEOF\necho logged`],
  ["heredoc body quoting a redirect into a main", "allow", envTheme, mainTheme, `cat >> log.md <<'EOF'\necho hi > ${mainPlugin}/x.php\nEOF`],
  ["redirect into a main after a heredoc still counts", "deny", envTheme, mainTheme, `cat >> log.md <<'EOF'\nnote\nEOF\necho hi > ${mainPlugin}/x.php`],
  // One command per line: a newline ends the previous command's arguments.
  ["second line's mutating git -C is not swallowed by the first line", "deny", envTheme, mainTheme, `git -C ${mainPlugin} status\ngit -C ${mainPlugin} commit -m x`],
  ["mv into a main on the first line, more lines after", "deny", envTheme, mainTheme, `mv x.php ${mainPlugin}/x.php\necho done`],
  ["rm on one line does not taint a read of a main on the next", "allow", envTheme, mainTheme, `rm -rf node_modules\nls ${mainPlugin}/src`],
  ["rm then cat of a main file on the next line", "allow", envTheme, mainTheme, `rm -f style.css\ncat ${mainTheme}/CLAUDE.md`],
  ["backslash continuation keeps one command together (mv)", "deny", envTheme, mainTheme, `mv x.php \\\n  ${mainPlugin}/x.php`],
  ["backslash continuation keeps one command together (rm)", "deny", envTheme, mainTheme, `rm -rf \\\n  ${mainPlugin}/vendor`],
  // Destroying the env the shell stands in, in every spelling that reaches the script.
  ["destroy of the env the shell stands in (in-tree script copy)", "deny", envTheme, mainTheme, `./scripts/agent-env-wp.sh destroy envx`],
  ["destroy of that env via the main checkout's script path", "deny", envTheme, mainTheme, `${mainTheme}/scripts/agent-env-wp.sh destroy envx`],
  ["destroy of that env after a cd elsewhere in the same line", "deny", envTheme, mainTheme, `cd /tmp && ./scripts/agent-env-wp.sh destroy envx`],
  ["destroy with a quoted script path", "deny", envTheme, mainTheme, `bash "${mainTheme}/scripts/agent-env-wp.sh" destroy envx`],
  ["destroy with a quoted relative script path", "deny", envTheme, mainTheme, `"./scripts/agent-env-wp.sh" destroy envx`],
  ["destroy with an assignment prefix", "deny", envTheme, mainTheme, `AGENT_ENV_FORCE=1 ./scripts/agent-env-wp.sh destroy envx`],
  ["destroy via env(1)", "deny", envTheme, mainTheme, `env FOO=1 ./scripts/agent-env-wp.sh destroy envx`],
  ["destroy via nohup", "deny", envTheme, mainTheme, `nohup ./scripts/agent-env-wp.sh destroy envx`],
  ["destroy via bash -c", "deny", envTheme, mainTheme, `bash -c './scripts/agent-env-wp.sh destroy envx'`],
  ["destroy with a quoted env name", "deny", envTheme, mainTheme, `./scripts/agent-env-wp.sh destroy "envx"`],
  ["destroy of ANOTHER env from inside is the script's call", "allow", envTheme, mainTheme, `AGENT_ENV_FORCE=1 ./scripts/agent-env-wp.sh destroy other`],
  ["destroy from the main checkout", "allow", mainTheme, mainTheme, `./scripts/agent-env-wp.sh destroy envx`],
  ["heredoc body quoting the destroy line", "allow", envTheme, mainTheme, `cat >> log.md <<'EOF'\n- \`./scripts/agent-env-wp.sh destroy envx\` -> denied\nEOF`],
  ["other lifecycle commands from inside stay allowed", "allow", envTheme, mainTheme, `./scripts/agent-env-wp.sh serve envx`],
];

let failures = 0;
function report(ok, label) { if (!ok) failures++; console.log(`${ok ? "ok  " : "FAIL"} ${label}`); }

try {
  buildFixture();
  for (const [label, expected, cwd, project, command] of cases) {
    const r = run(cwd, project, command);
    report(r.decision === expected && r.status === 0 && r.stderr === "", `expected=${expected} got=${r.decision} status=${r.status}${r.stderr ? " stderr!" : ""}  ${label}`);
  }
  // The destroy denial names the checkout whose registry lists the env.
  {
    const r = run(envTheme, mainTheme, `./scripts/agent-env-wp.sh destroy envx`);
    report(r.reason.endsWith(`${mainTheme}/scripts/agent-env-wp.sh destroy envx`), "destroy denial names the creating checkout's script");
  }
  // Fail open: malformed or empty input allows silently with exit 0.
  for (const [label, raw] of [["malformed JSON", "{not json"], ["empty stdin", ""], ["other tool", JSON.stringify({ tool_name: "Edit", cwd: envTheme, tool_input: { file_path: `${mainPlugin}/x.php` } })]]) {
    const r = run(envTheme, mainTheme, "", raw);
    report(r.decision === "allow" && r.status === 0 && r.stdout === "" && r.stderr === "", `fails open on ${label}`);
  }
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
console.log(failures ? `${failures} FAILED` : "all cases passed");
process.exit(failures ? 1 : 0);
