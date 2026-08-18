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
- **Ports**: slot N → `<PORT_BASE + STRIDE*N>` (slot 1 = `<13002/13003>`). Each
  env takes the lowest free slot; `destroy` frees it for reuse.
- **Inside an env, NEVER run `<MAIN_DEV_CMD, e.g. npm run dev>`**: it is pinned
  to the main checkout's ports and collides. This is enforced by
  `<scripts/guard-not-in-env.cjs>`. Use `./scripts/agent-env.sh serve <name>`
  (background, PID-managed, health-checked; logs in the env's `logs/`). Most
  tasks need only `<TEST_CMD>` and `<BUILD_CMD>`; only `serve` when you need a
  live server.
- **Re-anchor after any restart or interruption.** A Claude restart drops the
  `EnterWorktree` tracking AND can silently reset the Bash cwd back to the main
  checkout on the default branch, so an env `<TEST_CMD>` / `git diff` can run
  against the wrong code and report a false result. The mechanical fix: run env
  verification through `./scripts/agent-env.sh run <name> -- <cmd>` (e.g.
  `... run <name> -- <TEST_CMD>`), which `cd`s into the env first, so the result
  is cwd-independent. Use it for any cwd-relative command after an interruption.
  Fallback for what `run` doesn't cover: verify `pwd` and `git branch
  --show-current`, then prefer `git -C <worktree>` or an explicit `cd` into the env.
- **Verification scope in an env**: the **full** suite should run in-env — `<TEST_CMD>`,
  `<BUILD_CMD>`, and the **E2E** suite if one exists (`serve` the env, then run the
  browser tests against its own ports; describe the exact command). <If E2E needed a
  project patch to run in-env, say so and link it. Only a GENUINELY fixed-address
  integration can't run on env ports — describe it, e.g. "Real-Outlook e2e is pinned
  to a sideloaded manifest + SSO Application ID URI at localhost:13000; use takeover
  QA or the main checkout." Delete that caveat if there's no fixed-address integration. >
- **Takeover QA** (testing an env's branch through the fixed external integration):
  stop the main dev server, then `<npm run serve <name>>` from the main checkout
  (shorthand for `./scripts/agent-env.sh serve <name> --main-ports`). When done,
  `<npm run stop <name>>` releases the main ports. <Delete if no fixed-address
  integration. >
- **Pre-PR workflow**: load the `agent-environments` skill and follow its pre-PR
  workflow. **The skill is the single source of truth**: which steps run, their
  order, what gets recorded, the commit/push policy, and where to stop. Restate
  none of it here, so the two can't drift. Add only what this project genuinely
  changes. <PROJECT OVERRIDES / ADDITIONS ONLY, if any. Examples: "`/manual-qa`
  must be user-driven, the UI only renders in `<HOST_APP>`, so generate the
  procedure and hand it off rather than driving a headless browser." Or an extra
  gate: "also run `<LINT_CMD>` before stopping." Delete this bracketed part if
  the project has none. >
- **Cleanup**: after merge, `<npm run destroy <name>>`. It refuses to remove
  anything dirty or unpushed (commits survive in the main repo's `.git`
  regardless). Merged branches are deleted automatically so the name can be
  recreated; unmerged branches are kept (`create <name> --resume` reattaches one).
- **Dependencies auto-reconcile after a pull.** A committed git hook (`.githooks/`,
  installed by the env system) runs `<SYNC_CMD, e.g. npm install>` whenever a
  merge/pull/rebase changes `<LOCKFILES, e.g. package-lock.json>`, so the checkout
  can't end up with a manifest listing a package nobody installed. Don't be
  surprised by an install on `git pull`; don't `rm` `.githooks/`.
- **<Someone else may be working in the main checkout.>** <Include this bullet
  when a person also works in this repo directly (the human+agent mode); delete
  it for agent-only repos. > Never assume the main checkout is on the default
  branch: `./scripts/agent-env.sh list` prints its current branch and dirty
  state, and `create`/`provision` print it too. Envs always branch from the base
  ref (default `main`), never from whatever is checked out there. Don't switch
  branches, stash, `git clean`, or take the main ports (takeover QA) in that
  checkout without asking first; `git stash` in particular is one shared list
  across all worktrees.
- **Never run `git clean -fdx` at the main checkout root**: envs are nested and
  gitignored, so `-x` would delete them all.
- **Branch naming is automatic** (`<worktree>-<name>`); don't hand-rename env
  branches. `provision` owns and enforces the name.
