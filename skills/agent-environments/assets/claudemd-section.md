<!--
  TEMPLATE: splice this into the project's CLAUDE.md and replace every <PLACEHOLDER>.
  Keep it short. This is the always-loaded layer: project-specific facts plus the
  few safety rules that must hold even when the agent-environments skill isn't loaded.
  The full mechanics, setup workflow, and rationale live in the agent-environments skill.
-->

## Agent Environments (parallel agent work)

`scripts/agent-env.sh` spins up isolated environments so multiple coding agents
can work in parallel. Each env is a git worktree at `.claude/worktrees/<name>`
with CoW-cloned `<DEPENDENCY_DIRS, e.g. node_modules>`, its own `<CONFIG_FILE, e.g. .env>`
with a unique port set, and a logs dir. <ONE LINE on stateful services: e.g.
"There are no local stateful services in this project, so that IS the complete
environment." OR "Each env also gets its own database `<scheme>_<name>` and a
queue worker." >

- **Create your own env mid-session**: `EnterWorktree` with a task-derived name,
  then `./scripts/agent-env.sh provision`. Or adopt a pre-built env via
  `EnterWorktree` with `path: .claude/worktrees/<name>` (built with
  `./scripts/agent-env.sh create <name>`).
- **Ports**: slot N → `<PORT_BASE + 10N>` … (slot 1 = `<13010/13011>`). Slots
  stick to names across recreate, so ports are deterministic.
- **Inside an env, NEVER run `<MAIN_DEV_CMD, e.g. npm run dev>`**: it is pinned
  to the main checkout's ports and collides. This is enforced by
  `<scripts/guard-not-in-env.cjs>`. Use `./scripts/agent-env.sh serve <name>`
  (background, PID-managed, health-checked; logs in the env's `logs/`). Most
  tasks need only `<TEST_CMD>` and `<BUILD_CMD>`; only `serve` when you need a
  live server.
- **Re-anchor after any restart or interruption.** A Claude restart drops the
  `EnterWorktree` tracking AND can silently reset the Bash cwd back to the main
  checkout on the default branch, so an env `<TEST_CMD>` / `git diff` can run
  against the wrong code and report a false result. Before tests, builds, or
  commits after any interruption, verify `pwd` and `git branch --show-current`,
  and prefer `git -C <worktree>` or an explicit `cd` into the env.
- **Verification scope in an env**: `<TEST_CMD>`, `<BUILD_CMD>`, curl/supertest
  against the env's own ports. <Anything pinned to a fixed external address can't
  run on env ports, describe it: e.g. "Real-Outlook e2e can't run against env
  ports (the sideloaded manifest + SSO Application ID URI are pinned to
  localhost:13000); use takeover QA below or the main checkout." Delete this
  bullet if the project has no fixed-address integration. >
- **Takeover QA** (testing an env's branch through the fixed external integration):
  stop the main dev server, then `<npm run serve <name>>` from the main checkout
  (shorthand for `./scripts/agent-env.sh serve <name> --main-ports`). When done,
  `<npm run stop <name>>` releases the main ports. <Delete if no fixed-address
  integration. >
- **Cleanup**: after merge, `<npm run destroy <name>>`. It refuses to remove
  anything dirty or unpushed (commits survive in the main repo's `.git`
  regardless). Merged branches are deleted automatically so the name can be
  recreated; unmerged branches are kept (`create <name> --resume` reattaches one).
- **Never run `git clean -fdx` at the main checkout root**: envs are nested and
  gitignored, so `-x` would delete them all.
- **Branch naming is automatic** (`<worktree>-<name>`); don't hand-rename env
  branches. `provision` owns and enforces the name.
