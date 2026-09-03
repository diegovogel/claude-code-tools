// Pipe-tests agent-env-session-context.sh against real git repos laid out like
// a WordPress agent env: a main install with a theme and a plugin checkout, and
// an env install where the theme is a linked worktree and the plugin is a CoW
// snapshot. Run with `node <this file>`; exits non-zero on any failure. Tests
// the copy of the hook next to this file.
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const hook = path.join(__dirname, "../assets/agent-env-session-context.sh");
const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "session-ctx-")));
const main = path.join(root, "mainsite");
const env = path.join(root, "envs", "site__envx");
const mainTheme = path.join(main, "wp-content/themes/t");
const mainPlugin = path.join(main, "wp-content/plugins/p");
const envTheme = path.join(env, "wp-content/themes/t");
const envPlugin = path.join(env, "wp-content/plugins/p");
const registry = path.join(mainTheme, ".agent-env/wp/envx/meta.env");
const log = path.join(root, ".claude/agent-env-hooks.log");

function git(cwd, ...args) {
  const r = spawnSync("git", args, { cwd, encoding: "utf8", env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" } });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr}`);
  return r.stdout.trim();
}

function run(cwd, source, project) {
  const e = { ...process.env, HOME: root }; // the hook's log lands under $HOME/.claude
  delete e.CLAUDE_PROJECT_DIR;
  if (project) e.CLAUDE_PROJECT_DIR = project;
  const r = spawnSync("bash", [hook], { input: JSON.stringify({ cwd, source }), env: e, encoding: "utf8" });
  return { out: r.stdout, status: r.status, stderr: r.stderr };
}

let failures = 0;
function check(label, ok) { if (!ok) failures++; console.log(`${ok ? "ok  " : "FAIL"} ${label}`); }

try {
  for (const d of [mainTheme, mainPlugin, path.join(env, "wp-content/themes"), path.join(env, "wp-content/plugins"), path.join(root, ".claude")]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(main, "wp-config.php"), "<?php\n");
  fs.writeFileSync(path.join(env, "wp-config.php"), "<?php\n");
  for (const repo of [mainTheme, mainPlugin]) {
    git(repo, "init", "-q", "-b", "main");
    fs.writeFileSync(path.join(repo, "style.css"), "/* */\n");
    git(repo, "add", ".");
    git(repo, "commit", "-q", "-m", "init");
  }
  git(mainTheme, "worktree", "add", "-q", envTheme, "-b", "worktree-envx");
  fs.cpSync(mainPlugin, envPlugin, { recursive: true });
  fs.mkdirSync(path.dirname(registry), { recursive: true });
  fs.writeFileSync(registry, "AGENT_ENV_NAME=envx\n");

  const inEnv = run(envTheme, "compact", mainTheme);
  check("exits 0 with nothing on stderr", inEnv.status === 0 && inEnv.stderr === "");
  check("names the env and site", inEnv.out.includes("agent env 'envx' (site 'site')"));
  check("lists the theme main (pointer) as the creator", inEnv.out.includes(`- ${mainTheme}  (created this env`));
  check("lists the plugin main although the env only snapshotted it", inEnv.out.includes(`- ${mainPlugin}`));
  check("teardown names the owner's script and destroy", inEnv.out.includes(`${mainTheme}/scripts/agent-env-wp.sh destroy envx`));
  check("teardown says to move the session first", inEnv.out.includes("change_directory"));
  check("mentions the ExitWorktree escape for a bound session", inEnv.out.includes('ExitWorktree with action "keep"'));
  check("appends a log line", fs.existsSync(log) && fs.readFileSync(log, "utf8").includes("source=compact") && fs.readFileSync(log, "utf8").includes("env=envx"));

  // The launch directory is not a signal: after an app restart it is the env itself.
  const afterRestart = run(envTheme, "resume", envTheme);
  check("same guidance when the project dir is the env itself (app restart)", afterRestart.out.replace("SessionStart(resume)", "SessionStart(compact)") === inEnv.out);

  check("fires for /clear too (no matcher in settings)", run(envTheme, "clear", mainTheme).out.includes("SessionStart(clear)"));

  const fromSnapshot = run(envPlugin, "startup", mainTheme);
  check("from inside the snapshot plugin: both mains still found", fromSnapshot.out.includes(mainPlugin) && fromSnapshot.out.includes(mainTheme));

  fs.rmSync(registry);
  const noOwner = run(envTheme, "startup", mainTheme);
  check("no registry anywhere: generic teardown text, no creator marker", noOwner.out.includes(`.agent-env/wp/envx exists`) && !noOwner.out.includes("(created this env;"));

  // Generic engine layout: a worktree under <repo>/.claude/worktrees/ of a repo with scripts/agent-env.sh.
  const repo = path.join(root, "node-app");
  const wt = path.join(repo, ".claude/worktrees/task-a");
  fs.mkdirSync(path.join(repo, "scripts"), { recursive: true });
  git(repo, "init", "-q", "-b", "main");
  fs.writeFileSync(path.join(repo, "scripts/agent-env.sh"), "#!/bin/sh\n"); fs.chmodSync(path.join(repo, "scripts/agent-env.sh"), 0o755);
  git(repo, "add", "."); git(repo, "commit", "-q", "-m", "init");
  git(repo, "worktree", "add", "-q", wt, "-b", "worktree-task-a");
  const generic = run(wt, "compact", repo);
  check("generic worktree: names the env, the main checkout and the worktree", generic.out.includes("agent env worktree 'task-a' of " + repo) && generic.out.includes(wt));
  check("generic worktree: ExitWorktree keep first, then destroy from main", generic.out.includes('ExitWorktree with action "keep"') && generic.out.includes(`${repo}/scripts/agent-env.sh destroy task-a from ${repo}`));
  check("generic worktree: silent from the main checkout itself", run(repo, "startup", repo).out === "");
  const plainWt = path.join(root, "plain-wt");
  git(mainPlugin, "worktree", "add", "-q", plainWt, "-b", "plain");
  check("a hand-made worktree of a repo without the engine is not an env", run(plainWt, "startup", mainPlugin).out === "");

  check("silent outside any env", run(mainTheme, "startup", mainTheme).out === "");
  check("silent in a WP install without the __ marker", run(main, "startup", main).out === "");
  const bad = spawnSync("bash", [hook], { input: "{not json", env: { ...process.env, HOME: root }, encoding: "utf8" });
  check("fails open on malformed input (cwd falls back to the shell's, outside any env)", bad.status === 0 && bad.stdout === "");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
console.log(failures ? `${failures} FAILED` : "all cases passed");
process.exit(failures ? 1 : 0);
