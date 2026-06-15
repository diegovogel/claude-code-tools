---
name: agent-environments
description: >-
  Use this skill to give coding agents their own isolated, parallel workspaces on
  one repo. Trigger it whenever the user wants to: run several Claude/coding agents
  (or one agent across multiple tasks) on the same repo at once without them
  clashing; "set up agent environments" or parallel isolated sandboxes;
  create/provision/serve/list/destroy an isolated environment off a branch; give
  each git worktree its own ports, dependencies (node_modules/vendor/.venv), or
  database automatically; or stop two dev servers (e.g. `npm run dev`) fighting
  over the same port. Also trigger when operating an existing setup:
  `scripts/agent-env.sh` or `agent-env serve` failing with "port in use," or
  recovering a worktree whose work looks lost after a Claude restart (tests pass or
  `git diff` empty against the wrong checkout). It adapts to Node, Laravel,
  WordPress (a theme/plugin inside a full install), Python, and other stacks. Don't
  trigger for a single `git worktree add`, a language
  virtualenv, nvm version pinning, a devcontainer, CI/test parallelism, or
  deploying to a server.
---

# Agent Environments

This skill stands up and runs **isolated parallel environments** for coding
agents. An environment is a git worktree under `.claude/worktrees/<name>`,
provisioned to run the whole project in isolation: copy-on-write-cloned
dependencies, a unique port set, its own config and logs, and (where a stack has
local state) its own database/services. Several environments run at once without
fighting over ports, dependencies, or branches, so multiple agents (or you,
across multiple tasks) can work truly in parallel.

The system is a single project-local script, `scripts/agent-env.sh`, plus a
small in-dev guard and a short CLAUDE.md section. This skill ships a clean,
validated **reference** of all three (in `assets/`) and the guidance to adapt
them. Each project keeps its **own** copy of the script (self-contained, so it
works on CI and for collaborators who don't have this skill); the skill is the
durable home for the engine and the operating rules.

## First: are you operating, or setting up?

- The project **already has** an env system, `scripts/agent-env.sh` (the standard
  case), `scripts/agent-env-wp.sh` (the WordPress sub-component case), or a
  `.claude/worktrees/` with envs in it → you're **operating**. Jump to
  [Operating](#operating-an-existing-setup); for a WordPress setup the lifecycle
  commands live in [`references/wordpress.md`](references/wordpress.md).
- It **doesn't**, and the user wants parallel-agent isolation, an isolated
  sandbox for a branch, or "set up agent environments" → you're **setting up**.
  Go to [Setting up](#setting-up-in-a-new-project) (first decide whether the repo
  is itself the runnable project or a sub-component of one, see the exception
  callout there).

When in doubt, check:
`test -f scripts/agent-env.sh -o -f scripts/agent-env-wp.sh && echo operating || echo setup`.

## Operating an existing setup

Lifecycle (run from the **main checkout** unless noted; projects usually wrap the
common ones in `npm run`/`composer`/`make`, so check the project's CLAUDE.md and
package scripts for the exact wrappers):

| Command | What it does |
|---|---|
| `scripts/agent-env.sh create <name>` | New worktree + canonical branch + provision |
| `scripts/agent-env.sh provision [path]` | Provision an existing worktree (idempotent) |
| `scripts/agent-env.sh serve <name>` | Start the env's dev stack on its own ports (background, health-checked) |
| `scripts/agent-env.sh stop <name>` | Stop that env's dev stack |
| `scripts/agent-env.sh list` | All envs: branch / dirty / unpushed / ports / serving |
| `scripts/agent-env.sh destroy <name>` | Guarded teardown (refuses dirty/unpushed work) |

To create an env to work in *yourself* mid-session: `EnterWorktree` with a
meaningful task-derived name, then run `scripts/agent-env.sh provision`. Or adopt
a pre-built one: `EnterWorktree` with `path: .claude/worktrees/<name>`.
`EnterWorktree` adopts any worktree that appears in `git worktree list`, and
never removes an adopted worktree on `ExitWorktree`, so both paths are safe.

### The cardinal rules (why they exist)

These hold whenever you touch an env, so they're stated tersely in the project's
CLAUDE.md too. The reasoning:

- **Never run the main dev command inside an env.** It's pinned to the main
  checkout's ports and collides with the main dev server. Use
  `agent-env.sh serve <name>`, which runs on the env's *own* ports. The project
  enforces this with a guard, but don't rely on the guard. Know the rule.
- **Re-anchor after any restart or interruption.** A Claude restart (e.g.
  hitting a usage limit) drops `EnterWorktree` tracking *and* can silently reset
  the Bash cwd back to the main checkout on the default branch. Then an env
  `npm test` / `git diff` runs against the **wrong code** and reports a false
  result: a passing suite for code you didn't change, an empty `main...HEAD`
  diff. Before any test, build, or commit after an interruption, verify `pwd`
  and `git branch --show-current`, and prefer `git -C <worktree>` or an explicit
  `cd` into the env over trusting the cwd.
- **What you can verify in an env**: unit/integration tests, builds, and
  curl/supertest against the env's own ports. Anything pinned to a **fixed
  external address** (a sideloaded manifest, an OAuth redirect URI, a webhook,
  a browser-extension host) can't run on an env's ports. Use takeover QA or the
  main checkout.
- **Takeover QA** runs an env's branch *on the main ports* so a fixed external
  integration exercises it: stop the main dev server, then
  `serve <name> --main-ports`; release the ports with `stop` when done. The
  mechanism is exported env vars beating the config file, so no files change.
- **Teardown is guarded, so use it**: don't `rm -rf` an env or hand-delete its
  branch. `destroy` refuses to remove dirty or unpushed work; it auto-deletes a
  branch only once it's merged into `origin/main` (so `destroy` → `create` reuses
  the name), and keeps unmerged branches as a recovery net (`create <name>
  --resume` reattaches one). Commits survive in the main repo's `.git` regardless.
- **Never `git clean -fdx` at the main checkout root.** Envs are nested and
  gitignored, so `-x` would delete every one of them.
- **Don't hand-rename env branches.** `provision` owns and enforces the canonical
  name (`worktree-<name>` by default) in the one place both creation paths run
  through, so they can't diverge.

## Setting up in a new project

The goal: drop a self-contained, adapted `scripts/agent-env.sh` into the repo,
wire the guard and wrappers, and add the CLAUDE.md section. The engine is
copied verbatim; you fill in a fenced per-project section.

> **Exception: the repo is a sub-component of a larger runnable app.** If the
> thing you run isn't the git repo itself but an app the repo lives *inside* (the
> canonical case: a WordPress theme/plugin nested in a full WP install), the
> engine's "worktree = project" model doesn't fit, the env has to be the whole app
> with the repo swapped in. That needs a different flow; see
> [`references/wordpress.md`](references/wordpress.md), which ships its own script
> [`assets/agent-env-wp.sh`](assets/agent-env-wp.sh) (reusing the engine's slot,
> guard, and pid primitives). Use the steps below only when the repo is itself the
> runnable project (Node, Laravel, Python, etc.).

### 1. Assess the project

Figure out the eight adaptation knobs (full detail in
[`references/stacks.md`](references/stacks.md), read it before adapting; for a
full non-Node fill-in see [`references/laravel.md`](references/laravel.md)):

1. **Dependency dirs** to CoW-clone (`node_modules`, `vendor`, `.venv`, …) and
   the lockfile-reconcile command.
2. **Local artifacts** to seed (dev certs, fixtures), and secrets to *not* copy.
3. **Port count + config keys**: how many ports the dev stack binds, and the keys
   that name them.
4. **Dev/serve launch**: how to start the app for local dev (often several
   processes), and the URL(s) that mean "up".
5. **Stateful services to create**: does each env need its own DB / cache / queue /
   index so parallel runs don't corrupt each other? The axis that most changes the
   work. Many stacks need it; the Node example needs none.
6. **Stateful teardown**: what per-env state outlives the worktree and must be
   removed on destroy (a MySQL schema, a cache namespace)? File-backed state
   (SQLite) needs nothing, it goes away with the worktree.
7. **Fixed-address integration**: is there one (manifest, redirect URI, webhook)?
   That decides whether takeover QA applies.
8. **The main dev command name** (for the guard's message) and where to wire the
   wrapper commands (package.json scripts / composer / Makefile).

Inspect the repo and ask the user where it's genuinely ambiguous (especially
stateful services and fixed-address integrations, those aren't always visible
in the code).

### 2. Copy the assets

Copy [`assets/agent-env.sh`](assets/agent-env.sh) and
[`assets/guard-not-in-env.cjs`](assets/guard-not-in-env.cjs) into the project's
`scripts/`. `chmod +x scripts/agent-env.sh`.

### 3. Fill the per-project section

In `scripts/agent-env.sh`, edit **only** the fenced `PER-PROJECT SECTION` (the
CONFIG block + the seven `project_*` hooks). The shipped values are a worked
example for a Vite+Express Node project; keep what fits, rewrite what doesn't,
using [`references/stacks.md`](references/stacks.md) for each hook and
[`references/laravel.md`](references/laravel.md) for a full Laravel/PHP fill-in
(SQLite + MySQL, queue worker, per-env DB). Leave the engine below the fence
untouched. One CONFIG scalar needs cross-repo coordination: set **`PORT_BASE`** to
a band no other repo on this machine uses, ports are machine-global and the shipped
default `13000` collides if two repos keep it (probe + detail in
[`references/stacks.md`](references/stacks.md)).

### 4. Wire the guard and wrapper commands

- Prepend the guard to the dev command, e.g. in package.json:
  `"dev": "node scripts/guard-not-in-env.cjs && <real dev command>"`. For a
  non-Node stack, use the shell one-liner in `references/stacks.md` instead.
- Add convenience wrappers so the common operations are one word, e.g.:
  `"serve": "./scripts/agent-env.sh serve --main-ports"`,
  `"stop": "./scripts/agent-env.sh stop"`,
  `"destroy": "./scripts/agent-env.sh destroy"`.
  (npm forwards positional args without `--`, so `npm run serve <name>` works;
  flags like `--force` need the script called directly.)

### 5. Add the CLAUDE.md section

Splice [`assets/claudemd-section.md`](assets/claudemd-section.md) into the
project's CLAUDE.md and replace every `<PLACEHOLDER>`. Keep it short: it's the
always-loaded layer (project facts + the few safety rules that must hold even
when this skill isn't loaded). The full mechanics stay in this skill.

### 6. Gitignore the artifacts

Ensure these are gitignored: the config file the managed block writes to (e.g.
`.env`), the dependency dirs, `logs/`, and `.claude/`. The script writes
`.agent-env/` and `.agent-env.json` into `.git/info/exclude` itself. **The
config file must be gitignored**. Otherwise provision's managed-block edit
shows the worktree as dirty and the destroy guard blocks cleanup.

### 7. Smoke-test

From the main checkout: `create <name>` → `list` (confirm distinct ports, the
env shows up) → `provision <name>` again (idempotent) → if feasible,
`serve <name>` then hit a health URL then `stop` → `destroy <name>`. The engine
itself is validated; this confirms your per-project functions are wired right.

## How it works (the load-bearing design choices)

- **Worktrees live in `.claude/worktrees/`** (the runtime's own location), so
  Claude can `EnterWorktree` into them. The runtime's auto-cleanup sweep can't
  touch them because it requires no untracked files and a provisioned env always
  has some (config, deps, `.agent-env.json`). Relocating is a one-line CONFIG
  change if non-Claude agents ever need them elsewhere.
- **Deterministic ports** come from a slot registry
  (`<main>/.agent-env/slots/<name>`): a name keeps its slot forever, even across
  destroy/recreate, so an env's ports never change under you. Slot N → ports
  `PORT_BASE + STRIDE*N …`.
- **CoW dependency cloning** is the speed win: an env is ready in seconds and
  costs ~zero disk until its files diverge from main.
- **A managed block** in the config file (between markers) carries the env's
  ports while preserving everything else; it's regenerated every provision.
- **Guarded teardown** means the system never silently destroys work: dirty or
  unpushed envs are refused, and unmerged branches outlive their worktrees.

## Files in this skill

- [`assets/agent-env.sh`](assets/agent-env.sh): the reference script: fenced
  per-project section (worked Node/Vite example) over a stack-agnostic engine.
- [`assets/guard-not-in-env.cjs`](assets/guard-not-in-env.cjs): the in-dev guard.
- [`assets/claudemd-section.md`](assets/claudemd-section.md): templated CLAUDE.md
  section (the thin always-loaded layer).
- [`references/stacks.md`](references/stacks.md): per-knob and per-stack
  adaptation detail (Node, Laravel, Python, Rust), OS/CoW notes, and the gotchas.
  Read this before adapting the script to a new project.
- [`references/laravel.md`](references/laravel.md): a complete worked Laravel/PHP
  per-project section (serve via `artisan serve` not Herd, SQLite/MySQL/Redis
  isolation, queue worker, per-env DB create + drop), plus dogfooding targets.
- [`assets/agent-env-wp.sh`](assets/agent-env-wp.sh): a WordPress-specific flow for
  when the git repo is a theme/plugin inside a full install, the env clones the
  whole WP install and nests the repo as a worktree. Reuses the engine's primitives.
- [`references/wordpress.md`](references/wordpress.md): the WordPress model and its
  hard-won gotchas (`wp server` workers, browser-sync, `--skip-plugins`, URL /
  search-replace, per-env DB).
