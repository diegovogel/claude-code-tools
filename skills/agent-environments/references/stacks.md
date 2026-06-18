# Adapting agent-env.sh to a project

The engine in `assets/agent-env.sh` (everything below the `END PER-PROJECT
SECTION` line) is stack-agnostic. Adapting to a project means filling in the
**per-project section**: a CONFIG block and seven `project_*` hooks. This file
is the detail behind each; read the section you need. For a complete filled-in
example beyond the Node one shipped in the script, see [`laravel.md`](laravel.md)
(Laravel/PHP, but the same shape fits any stack).

## Contents
- [The adaptation surface (where the line is)](#the-adaptation-surface)
- [Dependencies: what to CoW-clone](#dependencies)
- [Ports and the config file](#ports-and-the-config-file)
- [The dev/serve command](#the-devserve-command)
- [Stateful services (DB, cache, queue, search)](#stateful-services)
- [Fixed-address takeover QA](#fixed-address-takeover-qa)
- [The in-env guard for non-Node stacks](#the-in-env-guard)
- [OS / copy-on-write notes](#os--copy-on-write-notes)
- [Gotchas that bite](#gotchas-that-bite)

## The adaptation surface

Everything that varies per project lives in exactly these eight places. This is
the line: the skill provides the machinery; you supply these.

| Knob | Where in the script | How to figure it out |
|---|---|---|
| Dependency dirs to clone | `project_seed_env_files` | What does a fresh checkout install that's slow/large? (`node_modules`, `vendor`, `.venv`, `target`) |
| Lockfile reconcile | `project_seed_env_files` | The "install from lockfile" command (`npm ci`, `composer install`, `uv sync`) |
| Local artifacts to seed | `project_seed_env_files` | Dev certs, fixtures the app reads but git ignores, and git-ignored package-manager credentials (Composer `auth.json`, npm `.npmrc`) that private-registry installs need |
| Port count + config keys | `PORTS_PER_ENV`, `project_env_port_lines` | How many ports does the dev stack bind? What config keys name them? |
| Dev/serve launch | `project_start_servers`, `project_health_urls` | How do you start the app for local dev, and what URL means "up"? |
| Stateful services (create) | `project_after_provision` | Does each env need its own DB / queue / cache to not corrupt the others? |
| Stateful teardown | `project_pre_destroy` | What per-env state outlives the worktree and must be removed (a MySQL schema, a cache namespace)? |
| Fixed-address QA | `project_main_ports` | Is there an external integration pinned to specific ports/URLs? |

Plus the CONFIG scalars (`PORT_BASE`, `PORT_STRIDE`, `MAIN_DEV_CMD`,
`CANONICAL_BRANCH_PREFIX`, `WORKTREES_SUBDIR`).

`project_env_port_lines`, `project_after_provision`, and `project_pre_destroy`
each receive the env **name** and **slot** as leading args, use them for anything
that must be unique per env (a `<base>_<name>` database, a per-env key prefix).

## Dependencies

The whole speed win is CoW-cloning the dependency tree instead of reinstalling.
`clone_dir` (in the engine) already handles the OS split; you just name the dirs.

- **Node**: `node_modules`. Reconcile with `npm ci` (fresh) / `npm install` (branch changed deps). Worked example ships in the script. **Monorepos** (pnpm/yarn/npm workspaces) keep a `node_modules` at the root **and** one per workspace package — clone them all (a real pnpm-workspace setup needed all 7). The internal links pnpm/yarn create are relative, so they resolve inside the env once every `node_modules` is cloned; clone only the root and the per-package symlinks dangle.
- **PHP/Laravel**: `vendor` (Composer) **and** usually `node_modules` (Vite/Mix assets). Reconcile with `composer install` and `npm ci`.
- **Python**: `.venv` (or wherever the venv lives). Reconcile with `uv sync` / `pip install -r requirements.txt`. A CoW-cloned venv keeps the *source* checkout's absolute paths, which bites in two non-obvious ways beyond activation scripts / `pyvenv.cfg`:
  - **Editable installs (`pip install -e`) keep pointing at the source tree.** The `.pth`/finder the editable install wrote holds an absolute path to the *main* checkout's package dir, so `import yourpkg` in the env silently resolves to main's code — no error, just broken isolation (the env's tests pass against code you never changed). Re-run `pip install -e .` in `project_after_provision` to repoint it at the env (also picks up deps the branch added). Confirmed live: after the repoint, the package imported from the worktree, not the main checkout.
  - **Console-script shebangs point at the source venv's python.** `bin/pip`, `bin/pytest`, … are scripts whose `#!` line is the absolute path to the venv's python *at creation time* (the main checkout), so running `env/.venv/bin/pip` execs main's interpreter and installs into main's venv. Always invoke tools as `.venv/bin/python -m pip` / `-m pytest`: `bin/python` is a symlink whose prefix resolves from its own location, so it picks the env's venv. (If activation still misbehaves, recreate the venv per env.)
- **Rust**: `target` is large and CoW-clones well; deps are global in `~/.cargo` so often nothing to clone but `target` for warm incremental builds.

Reconcile against the **env branch's own lockfile**, not main's, a branch that
changed dependencies must get them. The example does this with a `cmp` of the
lockfile then a conditional install.

**Seed git-ignored package-manager credentials, or in-env installs 401.**
Private-registry auth lives in git-ignored files (Composer `auth.json`, npm
`.npmrc` tokens, `~/.netrc`, `pip.conf`, Cargo registry tokens). The worktree
doesn't inherit them, so the moment a branch adds or updates a dep, the reconcile
step's `install`/`require` hits the private registry and fails with a confusing
"must authenticate" / 401 error. Copy these from the main checkout in
`project_seed_env_files`. They're read-only credentials, so copying is safe
(unlike the rotating secret store below). Easy to miss, because a pure CoW clone
with no dependency changes needs no auth — it only bites the first time someone
runs `require`/`install` in an env.

Never CoW-copy a **shared mutable secret store** that two running servers would
fight over (e.g. an OAuth refresh-token file that rotates on use, two servers
refreshing the same token invalidate each other). Let each env acquire its own
on first sign-in. The example deliberately skips `.vp-sessions.json` for this
reason.

## Ports and the config file

Each env reserves `PORTS_PER_ENV` consecutive ports starting at
`PORT_BASE + PORT_STRIDE*slot`. `PORT_STRIDE` must be ≥ `PORTS_PER_ENV` so
adjacent slots can't overlap, and defaults to exactly `PORTS_PER_ENV` (the densest
packing, no wasted ports). Raise it only to reserve headroom for adding ports per
env later, or for round, readable port numbers. The engine refuses to run if
`PORT_STRIDE < PORTS_PER_ENV`.

**`PORT_BASE` is machine-global; pick a distinct one per repo.** The slot registry
keeps ports unique *within* a repo, but localhost ports are a host-wide resource:
if two repos on the same machine both keep the shipped default (`13000`), their
first envs land on the same port and collide the instant both serve (seen in the
wild: one repo's env wanted a port another repo's env had held for hours). So the
first adaptation step for a new repo is a `PORT_BASE` no other repo on the machine
uses, give each its own band (`13000`, `13100`, `13200`, etc.). At the default
`STRIDE=2` a 100-wide band holds ~50 envs, and because `destroy` frees slots (no
lifetime accumulation) that ceiling is about *concurrent* envs, which you'll never
approach. Probe for a free band:

```bash
for base in 13000 13100 13200 13300 13400 13500 13600 13700 13800 13900; do
  busy=0
  for off in 1 2 3 10 20; do          # sample low + round-stride offsets in the band
    lsof -nP -iTCP:$((base+off)) -sTCP:LISTEN -t >/dev/null 2>&1 && { busy=1; break; }
  done
  (( busy )) || { echo "free band: PORT_BASE=$base"; break; }
done
```

This only sees bands whose ports are *currently* listening (an idle env's reserved
band reads as free), so it prevents the common case; the runtime `serve` check is
the backstop for the rest, it fails loudly and names the cross-repo cause so you
bump `PORT_BASE` and re-provision.

`project_env_port_lines` maps those ports to the keys the dev stack reads. The
mapping is not always 1:1: the worked example writes **two** ports into **three**
keys because the proxy target (`DEV_API_PORT`) is deliberately separate from a
prod-like `API_PORT` that the base `.env` also sets. Whenever a framework reads a
port from two different keys in two modes, give it two keys here so an env can't
accidentally pick up the main checkout's value.

The managed block is written into the config file (`.env` by default) between
markers, preserving everything else. **The config file must be gitignored**, or
provision's edit registers as a dirty worktree and the destroy guard refuses to
clean up. If the project's port config lives in a *tracked* file, write a
gitignored overlay instead (e.g. `.env.local`) and change the `.env` region of
`cmd_provision` plus `project_env_port_lines`.

## The dev/serve command

`project_start_servers` launches the env's dev processes in the background,
writing one PID file per process into `.agent-env/` (the engine kills every
`.agent-env/*.pid` on stop, so naming is yours). It runs inside a `set -m`
subshell so each `&` job gets its own process group and stop kills whole trees.

`project_health_urls` lists `label|url|timeout_seconds` lines the engine polls
before declaring the env up. On any failure it tears the half-started stack back
down so the next `serve` doesn't see stale PID files.

This is the least portable function, local dev launch differs wildly:
- **Laravel**: `php artisan serve --port=<web>` + `npm run dev` (Vite) + maybe
  `php artisan queue:work`. Serve via `artisan serve`, NOT Herd/Valet (they are
  domain-based on :80, not per-port). Full worked example in [`laravel.md`](laravel.md).
- **Single-server apps**: one process, one PID file, one health URL.
- **Compiled/long-build apps**: you may want a build step before launch.

Keep it concrete to the project rather than abstracting; this is where pretend-
generic code turns to mush.

### Watcher / dev-server footgun (every stack)

Whatever you launch in `project_start_servers` must be safe to run unattended and
in parallel. Three traps, all hit in real projects:

- **Fixed ports.** A dev server on a hardcoded port (Vite's default 5173, Laravel
  Mix `hot`'s 8080, browser-sync's 3000) collides the instant a second env serves.
  Pass the env's own port (`vite --port=$p`) or use a watcher that binds nothing.
- **Holding the terminal / never returning.** Tools that open a browser or expect
  a TTY (browser-sync, some HMR/live-reload setups) can keep the caller's stdout
  open so `serve` never returns, and they're useless headless anyway. The engine
  runs `project_start_servers` with stdin detached (`</dev/null`); you should still
  redirect each process's output to a log (`>>logs/... 2>&1`) so nothing holds the
  pipe.
- **Compile-to-disk is the safe default.** A plain `sass --watch` / `tsc --watch`
  / `vite build --watch` writes files and binds no port, run it freely. If a
  project only ships a browser-sync/HMR script, run it manually instead of in
  `serve`. This is exactly why the WordPress flow doesn't auto-start watchers (see
  [`wordpress.md`](wordpress.md)), and why the Laravel example prefers Mix `watch`
  over `hot` (see [`laravel.md`](laravel.md)).

## Dev-server-dependent tests (E2E) in an env

A unit suite usually runs in an env with zero extra work (no ports, no server).
The suite that *fights* the env model is the one that drives a **running app** —
Playwright/Cypress E2E. The whole point of agent envs is that an agent can verify
its work, and "the full suite" includes E2E, so getting E2E to run in-env (and in
parallel) matters. Three blockers recur, and none can be fixed from the script
alone — they live in the project's own source. The fix for each is a
**backward-compatible** project patch: gate new behavior behind an env var that
defaults to today's behavior, and set that var only from `serve` / the in-env test
flow. The invariant: a teammate who pulls the change still runs the full suite on
the main checkout, without this skill, without `.env` edits.

1. **The dev server binds a hidden fixed global port.** Modern dev servers often
   start a *second* server on a hardcoded port for devtools / HMR / an event bus,
   independent of the `--port` you pass. Example seen in the wild: TanStack Start's
   `devtools()` Vite plugin starts an event bus on a fixed `42069`, so two `vite
   dev` processes collide even within one env (and the failure — `EADDRINUSE
   :::42069` deep in a plugin — doesn't name itself). You can't relocate it
   externally; gate it in the vite/webpack config behind an env var and set that var
   in `project_start_servers`:
   ```ts
   // vite.config.ts — default unchanged; serve sets APP_NO_DEVTOOLS=1
   devtools(process.env.APP_NO_DEVTOOLS ? { eventBusConfig: { enabled: false } } : undefined)
   ```
   Disabling devtools is fine for tests; if you'd rather keep them, give the bus a
   per-env port instead (read it from an env var, reserve one more port per env).

2. **The test runner hardcodes a baseURL/port.** Playwright pins `use.baseURL`,
   `webServer.url`, and often a `globalSetup` URL to `http://localhost:3000`.
   Parameterize each from one env var defaulting to today's value, AND skip the
   runner's own server management when it's set (otherwise Playwright starts a
   *second* dev server on the main port — which also re-triggers blocker 1):
   ```ts
   const BASE_URL = process.env.E2E_BASE_URL ?? "http://localhost:3000";
   // ...use.baseURL = BASE_URL; globalSetup reads BASE_URL...
   webServer: process.env.E2E_BASE_URL
     ? undefined                                   // env's `serve` already runs it
     : { command: "pnpm run dev", url: BASE_URL, reuseExistingServer: true },
   ```
   Write the per-env `E2E_BASE_URL=http://localhost:<web port>` into the managed
   `.env` block (`project_env_port_lines`) so the in-env flow can `source .env` and
   run `playwright test` with no other setup. (Don't rely on `reuseExistingServer`
   alone to dodge a second server — it probes the URL and is racy; skipping
   `webServer` outright when the caller owns the server is deterministic.)

3. **Gitignored generated artifacts the app imports.** If codegen output (proto/
   gRPC stubs, a generated client) is gitignored, a fresh worktree lacks it and the
   *dev server* 500s on import — so E2E fails with a server error, not a port error.
   The committed-stub side of the same contract (e.g. Python stubs that are checked
   in) works, which can mislead. Regenerate in `project_after_provision` (e.g.
   `moon run proto:build`); see [Dependencies](#dependencies) / knob 2.

Then `serve` the env (API + the one web app the E2E suite targets is enough) and
run `playwright test` against the env's port. With blocker 1 fixed, every env's
dev server avoids the shared fixed port, so envs run E2E in parallel.

## Stateful services

This is the axis that most changes the work. The worked example has **no local
state** (everything lives in remote SaaS APIs), so `project_after_provision` is
empty. Most stacks aren't so lucky.

If two envs share one database/cache/queue, they corrupt each other's test runs.
Give each env its own:

- **Database**: in `project_after_provision` (which receives the env name + slot),
  create a per-env DB named from the env (e.g. `myapp_<name>`), then migrate and
  seed it; write its name into the config file via `project_env_port_lines` (also
  given name + slot) so the app connects to the right one. **Teardown**: drop it in
  `project_pre_destroy` (runs during `destroy`, after the guards pass, before the
  worktree is removed). File-backed DBs (SQLite) need no teardown, they live in the
  worktree and vanish with it. See [`laravel.md`](laravel.md) for a worked
  SQLite + MySQL example.
- **Redis/cache**: cheapest isolation is a per-env key prefix
  (`REDIS_PREFIX=<name>_`, no limit) or a logical DB index per slot
  (`REDIS_DB=$slot`, but Redis has only 16 by default, so a prefix scales better).
  No new process needed.
- **Queue/worker**: start it in `project_start_servers` as another background
  process (another PID file), pointed at the env's own DB/redis.
- **Search (Elastic/Meili/etc.)**: per-env index prefix, created in
  `project_after_provision`.

Reserve extra ports for any service that binds one by bumping `PORTS_PER_ENV` and
mapping them in `project_env_port_lines`.

## Fixed-address takeover QA

Some apps have an external integration pinned to a specific port or URL: a
sideloaded add-in manifest, an OAuth redirect URI, a webhook target, a browser
extension's host permissions. You can't exercise an env's branch through that
integration on the env's own ports.

`--main-ports` "takeover" solves it: `project_main_ports` echoes the fixed port
set, and `serve --main-ports` runs the env's branch on those ports (after you
stop the main checkout's dev server). The mechanism is just exported env vars
beating the config file, so no file edits are needed.

If the project has **no** fixed-address integration, make `project_main_ports`
echo nothing, and `--main-ports` then errors loudly instead of silently doing the
wrong thing, and you drop the takeover bullets from the CLAUDE.md section.

## The in-env guard

`assets/guard-not-in-env.cjs` is a Node script wired as the first step of the dev
command (`node scripts/guard-not-in-env.cjs && <dev>`). It aborts when
`.agent-env.json` is present in cwd (the signal that you're inside an env). Node
keeps it cross-platform for projects that dev on Windows too.

For a non-Node stack, a shell guard in the dev script works the same way:

```bash
# at the top of your dev target / Makefile recipe
[ -f .agent-env.json ] && { echo "✖ dev is disabled inside an agent env; use agent-env.sh serve <name>"; exit 1; }
```

## OS / copy-on-write notes

`clone_dir` already branches on `uname`:
- **macOS / APFS**: `cp -c -R` (clonefile). Near-instant, near-zero disk.
- **Linux / btrfs or xfs**: `cp -R --reflink=auto`. CoW where the FS supports it;
  silently degrades to a full copy elsewhere (correct, just slower).
- **Other / Windows**: no CoW; `project_seed_env_files` falls back to a real
  install. Agent envs run on the dev machine, so target that machine's FS. v1 is
  validated on macOS/APFS.

## Gotchas that bite

- **Config file not gitignored** → provision dirties the worktree → destroy guard
  blocks cleanup. Gitignore it (see [Ports](#ports-and-the-config-file)).
- **One port read from two keys** → an env silently picks up the main checkout's
  value in one mode. Give it a distinct key per mode (the `DEV_API_PORT` story).
- **CoW-copying a rotating-secret store** → two servers invalidate each other's
  tokens. Skip it; let each env acquire its own.
- **`PORT_STRIDE < PORTS_PER_ENV`** → adjacent slots overlap. Keep stride ≥ count.
- **Two repos sharing `PORT_BASE`** → their same-numbered slots collide on
  localhost (the slot registry only dedups within one repo). Give each repo a
  distinct base (see [Ports](#ports-and-the-config-file)).
- **Envs based on old refs don't gitignore `.agent-env*`** → they'd read as dirt.
  The engine already writes those patterns into `.git/info/exclude` (shared
  across all worktrees) on provision, so this is handled, don't remove it.
- **`git clean -fdx` at the main root** wipes every nested env. Warn in CLAUDE.md.
- **A dirty lockfile in the main checkout dirties every env.** The reconcile step
  compares the env's lockfile to main's *working-tree* lockfile (`cmp "$main/<lock>"
  "$env/<lock>"`), so an uncommitted lockfile edit in main makes every new env run
  an install and then read as dirty — `destroy` then refuses without `--force`.
  Commit or stash the lockfile before spinning up envs. (Seen live: a dirty
  `pnpm-lock.yaml` made every env reconcile; once committed, fresh envs were clean.)
- **An app with async graceful shutdown holds its port for a beat after `stop`.**
  `stop` signals the process group, but a server that drains connections releases
  its socket a second or two later, so an immediate re-`serve` can hit "port in
  use." Poll `lsof` until the port frees before re-serving (the engine's own
  serve-after-stop is fine; this bites manual stop→serve loops).
- **The script may run under a restricted PATH** (e.g. the Claude sandbox), where
  only the homebrew dirs the engine prepends are present. If the build tool or
  language runtime lives elsewhere (moon at `~/.moon/bin`; asdf/proto/mise shims
  in their own dirs), `project_after_provision`'s codegen/build and
  `run <name> -- <tool>` fail with "not found." Add the needed bin dirs to PATH in
  the per-project section (one real setup adds `~/.moon/bin` and `~/.proto/bin`).
