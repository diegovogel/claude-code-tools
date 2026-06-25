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
  WordPress (a theme/plugin inside a full install), Python, Shopify themes (just a
  git worktree + a dev-server port, no engine needed), and other stacks. Don't
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
- The repo is a **no-local-state stack** (a Shopify theme; more generally, a dev
  server that only renders local files against a remote service, with no
  deps/DB/build to isolate) → there's **no engine** to install or operate. The env
  is just a git worktree + the dev server on a per-env port. Go straight to
  [`references/shopify.md`](references/shopify.md) for the full create/serve/teardown
  playbook.

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
| `scripts/agent-env.sh run <name> -- <cmd>` | Run a command **in** the env regardless of the shell's cwd (the re-anchor fix) |
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
  diff. The mechanical fix is `agent-env.sh run <name> -- <cmd>`: it resolves the
  env dir and `cd`s into it before running, so verification is cwd-independent no
  matter where the shell landed. Prefer it for every cwd-relative command after an
  interruption (`run <name> -- npm test`, `run <name> -- git diff`). It `exec`s the
  command directly, so shell features (pipes, inline env) need `run <name> -- bash
  -lc '...'`. As a fallback for what `run` doesn't cover, verify `pwd` and
  `git branch --show-current`, then prefer `git -C <worktree>` or an explicit `cd`
  into the env over trusting the cwd. Optional belt-and-suspenders: wire
  `assets/session-start-reanchor.sh` as a project `SessionStart` hook so a resumed
  session is reminded automatically — it lists the provisioned envs and the `run`
  form, and prints nothing when none exist.
- **Re-root file-tool paths to the worktree after `EnterWorktree`.** This is a
  distinct trap from the cwd reset above, and it bites in the *opposite*
  direction. `EnterWorktree` moves the session cwd, but it does **not** rewrite
  *absolute* paths — and the file tools (Read/Edit/Write) take absolute paths.
  Any path you captured by Reading a file during planning (before entering the
  worktree) still points at the **main checkout**. Reuse it in an Edit/Write and
  the change lands on `main`: because the worktree mirrors the tree, the path
  exists, the write succeeds with no error, and the worktree's `npm test` then
  validates unchanged code (a green suite for code you didn't change). After
  entering a worktree, derive every file-tool path from the worktree root; don't
  reuse planning-phase absolute paths. Verify once after your first edits:
  `git -C <worktree> status` shows them and `git -C <main> status` is clean. A
  `PreToolUse` hook (`assets/worktree-edit-guard.cjs`, wired in
  `~/.claude/settings.json`) blocks main-checkout edits from a worktree session
  as a backstop, but it loads at session start and is best-effort — know the
  rule. (Recovery if it already happened: the changes are uncommitted on `main`;
  `git -C <main> stash push -- <files>` then `git -C <worktree> stash pop` moves
  them onto the branch and leaves `main` clean — worktrees share one stash list.)
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

### The pre-PR workflow (in an env)

Once the implementation is done and verified in the env, run this sequence
**before** opening a PR. The point: land the quality, security, and review
passes while still isolated in the env, and stop at the PR boundary so the
human decides when to publish. Don't stop *before* these steps (a common
mistake) — only stop before the PR itself.

1. **Verify** — the env's own test + build commands, via `run <name> -- <cmd>`.
2. **`/simplify`** — quality cleanup of the diff (reuse, dead code, altitude).
3. **`/security-review-plus`** — *if warranted*. It's cheap, so the bar is low:
   run it whenever anything remotely security-relevant was touched (auth, input
   handling, network calls, file I/O, crypto, headers, middleware, rate limiting).
   Skip only for plainly non-security diffs (pure CSS, a variable rename, docs).
4. **`/manual-qa`** — exercise the change end-to-end. Default: **drive it
   yourself headlessly** — start the env's `serve` and hit it with `curl` for
   HTTP/back-end changes, or write *temporary* Playwright tests for UI (run
   them, do **not** commit them; if no headless browser is installed, suggest
   installing one). Don't use Preview or Claude-in-Chrome — too slow. If the UI
   genuinely can't be driven headlessly because it renders inside a host app
   (Outlook, an IDE, a mobile shell), produce the QA procedure and hand it to
   the user to drive instead. Doing this *before* Codex means it reviews
   more-correct code, and any trade-offs you weigh here become context you can
   use to defend your decisions in review.
5. **`/review-with-codex`** — automated review cycles until clean.
6. **Re-verify after Codex** — confirm functionality still works after any
   changes review applied (regressions tests may miss). If step 5 changed
   nothing, skip this. If it did, re-run step 1 (tests + build) and re-exercise
   the parts of the `/manual-qa` flow that touch what Codex changed — a full
   re-run only if the changes were broad. Manual QA is cheap, so when in doubt,
   re-run more rather than less.
7. **STOP before the PR.** Do not `git commit` / push / `gh pr create` unless
   the user asks. Report what steps 2–6 found and wait.

**Projects override these defaults.** A project's CLAUDE.md is authoritative: it
can pin which steps apply and how — e.g. "`/manual-qa` here must be user-driven
because the UI only renders in Outlook", or "skip `/review-with-codex`". When the
project's own section says something different, follow the project, not this default.

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

> **Exception: no local state to isolate (a Shopify theme).** If the repo has no
> dependency dirs, no local DB, and no build to clone or namespace, and its dev
> server only renders local files against a **remote** service (the canonical
> case: a Shopify theme served by `shopify theme dev` against a hosted store),
> the engine isolates nothing real, it would be empty hooks around a `--port`
> flag. **Don't install it.** The isolation that matters (parallel agents on
> non-clobbering copies of the code) comes from the git worktree alone, plus a
> per-env dev-server port. Skip the steps below entirely and follow
> [`references/shopify.md`](references/shopify.md).

### 1. Assess the project

Figure out the eight adaptation knobs (full detail in
[`references/stacks.md`](references/stacks.md), read it before adapting; for a
full non-Node fill-in see [`references/laravel.md`](references/laravel.md)):

1. **Dependency dirs** to CoW-clone (`node_modules`, `vendor`, `.venv`, …) and
   the lockfile-reconcile command — both the fresh-env reconcile
   (`project_seed_env_files`) and the post-pull reconcile that keeps the main
   checkout in sync (`project_sync_deps` + `LOCKFILES`, run by an auto-installed
   git hook; see `references/stacks.md`).
2. **Local artifacts** to seed (dev certs, fixtures, and **git-ignored
   package-manager credentials** like Composer `auth.json` or npm `.npmrc` tokens
   that private-registry installs need — git-ignored, so `provision` won't copy
   them, and a `require`/`install` in the env 401s without them), runtime secrets
   to *not* copy, and **gitignored generated build artifacts** (codegen output:
   proto/gRPC stubs, generated API clients, route trees). A fresh worktree lacks
   them and they aren't inside the dependency dirs, so seed credentials in
   `project_seed_env_files` and regenerate build artifacts in
   `project_after_provision` — else whatever imports them breaks in-env while
   passing on the main checkout, which already has them.
3. **Port count + config keys**: how many ports the dev stack binds, and the keys
   that name them.
4. **Dev/serve launch**: how to start the app for local dev (often several
   processes), and the URL(s) that mean "up". Note whether the **test suite needs
   that running server** (E2E/browser tests usually do): if so, the env must serve
   it, and any port or baseURL the suite or dev server hardcodes becomes a blocker
   to fix backward-compatibly (see step 8 and `references/stacks.md`).
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
CONFIG block + the eight `project_*` hooks, including `project_sync_deps` +
`LOCKFILES` for the post-pull dependency-sync hook). The shipped values are a worked
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

**Commit `.githooks/` — do NOT gitignore it.** The first `provision` (or, for
WordPress, `create`) auto-installs the dependency-sync git hooks there and points
`core.hooksPath` at it (idempotent, quiet). Commit the dir so worktrees and
collaborators inherit the hook; an untracked `.githooks/` works for your checkout
but vanishes on `git clean -fdx` and isn't checked out into worktrees. (You can
also run `scripts/agent-env.sh install-hooks` explicitly.) See
[`references/stacks.md`](references/stacks.md#keeping-the-main-checkout-in-sync-after-a-pull-project_sync_deps).

### 7. Smoke-test — and prove the FULL test suite runs in an env

From the main checkout: `create <name>` → `list` (confirm distinct ports, the
env shows up) → `provision <name>` again (idempotent) → `serve <name>` then hit a
health URL → `stop`. That validates your per-project functions are wired right.

Then prove the goal that matters most: **an env can run the project's _entire_
test suite, including E2E if one exists.** Run each suite in the env —
`agent-env.sh run <name> -- <unit/integration cmd>`, and for E2E, `serve` the env
and run the browser tests against the env's own ports. If everything passes,
`destroy <name>` and you're done. If the full suite does NOT run in-env, go to
step 8 — don't ship a setup where agents can only run part of the suite, since
"tests pass" then silently means "the tests that happen to work in isolation."

### 8. Make the full test suite runnable in an env (backward-compatibly)

If step 7 showed the suite can't fully run in-env (most often the E2E suite,
because it needs the dev server), the blocker lives in the project's own source —
the engine can't fix it from outside. Patch the project, but **only in a
backward-compatible way**, this is the hard requirement: anyone who pulls the
change MUST still run the full suite on the **main checkout**, **without this
skill**, **without editing their `.env`**. The pattern is always the same — gate
the new behavior behind an env var that DEFAULTS to today's exact behavior, and
have `serve` / the in-env test flow set that var. The three blockers:

- **The dev server binds a hidden fixed global port** — a devtools / HMR /
  telemetry / event-bus server on a hardcoded port, *separate* from the port you
  pass the dev server. Two dev servers then collide (across envs, often within one
  env), and you can't relocate it from outside. Gate it in the app's dev-server
  config behind an env var and set that var in `project_start_servers`, e.g.
  `devtools(process.env.APP_NO_DEVTOOLS ? { eventBusConfig: { enabled: false } } : undefined)`.
  Unset = unchanged.
- **The test runner hardcodes a baseURL/port** (Playwright `baseURL` /
  `webServer.url` / a global-setup URL; Cypress `baseUrl`). Read them from an env
  var defaulting to today's value —
  `const BASE = process.env.E2E_BASE_URL ?? "http://localhost:3000"` — and when the
  var is set, also skip the runner's own server-management (the env's `serve`
  already provides the server; otherwise the runner starts a second one on the main
  port). Record the per-env value in the managed `.env` block so the in-env flow can
  `source` it.
- **Gitignored generated artifacts are missing** (knob 2): regenerate in
  `project_after_provision`. No app change needed.

After patching, re-run step 7's full-suite check in a *fresh* env (so you exercise
provisioning, not a hand-fixed worktree), and document the in-env E2E command in
the CLAUDE.md section so agents can find it. See `references/stacks.md`
("Dev-server-dependent tests") for the worked patterns.

## How it works (the load-bearing design choices)

- **Worktrees live in `.claude/worktrees/`** (the runtime's own location), so
  Claude can `EnterWorktree` into them. The runtime's auto-cleanup sweep can't
  touch them because it requires no untracked files and a provisioned env always
  has some (config, deps, `.agent-env.json`). Relocating is a one-line CONFIG
  change if non-Claude agents ever need them elsewhere.
- **Per-env ports** come from a slot registry
  (`<main>/.agent-env/slots/<name>`): each env takes the lowest free slot, and
  slot N → ports `PORT_BASE + STRIDE*N …`, a unique non-overlapping set so
  parallel servers never collide. `destroy` frees the slot, so numbers stay low
  and dense and get reused (recreating a name may hand it different ports, which
  is fine, envs are disposable).
- **CoW dependency cloning** is the speed win: an env is ready in seconds and
  costs ~zero disk until its files diverge from main.
- **A managed block** in the config file (between markers) carries the env's
  ports while preserving everything else; it's regenerated every provision.
- **Guarded teardown** means the system never silently destroys work: dirty or
  unpushed envs are refused, and unmerged branches outlive their worktrees.
- **Dependency-sync git hooks** keep the *main checkout* from drifting: when a
  pull/merge/rebase changes a watched lockfile, a `post-merge`/`post-rewrite` hook
  runs the per-project `project_sync_deps` (e.g. `npm install`). It's the fix for
  the recurring trap where an env's PR adds a package, the lockfile merges into
  main, but nobody installs it there. Auto-installed by `provision`; the hooks
  just delegate to `agent-env.sh sync-deps` so the install logic lives only in the
  per-project section.

## Files in this skill

- [`assets/agent-env.sh`](assets/agent-env.sh): the reference script: fenced
  per-project section (worked Node/Vite example) over a stack-agnostic engine.
- [`assets/guard-not-in-env.cjs`](assets/guard-not-in-env.cjs): the in-dev guard.
- [`assets/worktree-edit-guard.cjs`](assets/worktree-edit-guard.cjs): a `PreToolUse`
  hook (wired in `~/.claude/settings.json`) that blocks Edit/Write/MultiEdit to
  the main checkout while the session is in an agent-env worktree — the backstop
  for the "re-root file-tool paths" cardinal rule. Fails open.
- [`assets/session-start-reanchor.sh`](assets/session-start-reanchor.sh): an optional
  `SessionStart` hook that reminds a resumed session to verify via `agent-env.sh run
  <name> -- <cmd>` when provisioned envs exist — the proactive companion to the
  re-anchor cardinal rule. Self-contained, silent when no envs exist, always exits 0.
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
