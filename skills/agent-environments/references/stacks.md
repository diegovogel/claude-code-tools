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
| Local artifacts to seed | `project_seed_env_files` | Dev certs, fixtures the app reads but git ignores |
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

- **Node**: `node_modules`. Reconcile with `npm ci` (fresh) / `npm install` (branch changed deps). Worked example ships in the script.
- **PHP/Laravel**: `vendor` (Composer) **and** usually `node_modules` (Vite/Mix assets). Reconcile with `composer install` and `npm ci`.
- **Python**: `.venv` (or wherever the venv lives). Reconcile with `uv sync` / `pip install -r requirements.txt`. Note: a venv contains absolute paths in some activate scripts and `pyvenv.cfg`; a CoW clone keeps the *original* paths. Usually fine because the worktree runs the same interpreter, but if activation misbehaves, fall back to recreating the venv per env.
- **Rust**: `target` is large and CoW-clones well; deps are global in `~/.cargo` so often nothing to clone but `target` for warm incremental builds.

Reconcile against the **env branch's own lockfile**, not main's, a branch that
changed dependencies must get them. The example does this with a `cmp` of the
lockfile then a conditional install.

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
