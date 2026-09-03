# Agent environments for WordPress (theme / plugin repos)

WordPress is the documented exception to the engine's "the git repo is the
runnable project" model. Here the repo is a **theme or plugin nested in
`wp-content/`**, but a runnable env needs the **whole WordPress install**. So WP
gets its own script, [`assets/agent-env-wp.sh`](../assets/agent-env-wp.sh), which
reuses the engine's primitives (slot/port registry, the `unique_commits` destroy
guard, pid/health machinery, CoW clone) but with a WP-specific flow.

**Run it from the theme/plugin repo's main checkout**; it finds the enclosing WP
install automatically. `destroy` refuses to run from inside the env it would delete.

## Lifecycle

Run from the theme/plugin repo's main checkout (projects usually wrap the
common ones; check the CLAUDE.md):

| Command | What it does |
|---|---|
| `scripts/agent-env-wp.sh create <name> [base-ref]` | CoW-clone the install, worktree(s) on `worktree-<name>`, per-env DB, URL, deps, build step |
| `scripts/agent-env-wp.sh run <name> -- <cmd>` | Run a command in the env's own worktree, whatever the shell's cwd (the re-anchor fix) |
| `scripts/agent-env-wp.sh serve <name>` | `wp server` on the env's port, background, health-checked |
| `scripts/agent-env-wp.sh stop <name>` | Stop that server |
| `scripts/agent-env-wp.sh list` | Every env of this repo: branch, port, DB, serving; plus the main checkout's branch and dirty state |
| `scripts/agent-env-wp.sh destroy <name> [--force]` | Guarded teardown of every worktree, the DB, the clone and the slot; refuses from inside the env |
| `scripts/agent-env-wp.sh install-hooks` | (Re)install the dependency-sync git hooks; `create` does this itself |
| `scripts/agent-env-wp.sh sync-deps` | What those git hooks call after a pull changed a lockfile |

`run` and `serve` refuse an env whose `create` did not finish (its wp-config may
still name the source database); `destroy` and `list` accept it.

## The model

An env is:
- a **copy-on-write clone of the entire WP install** (core + all of wp-content +
  uploads), placed outside Herd's parked dirs (`~/WebDev/Sites/.wp-agent-envs/`
  by default) so it isn't auto-served as a `.test` domain;
- with the **target theme/plugin replaced by a git worktree** of your repo (on
  branch `worktree-<name>`), nested at its normal `wp-content/...` path, and the
  same for every repo in `SIBLING_REPOS` (see
  [Sibling repos](#sibling-repos-theme--plugin-in-one-env));
- its **own database** (`wp_<site>_<env>`, copied from the site), and
- its **own port**, served with `wp server`, from a slot pool shared by every
  env under `ENV_PARENT` on the machine.

```
create  -> CoW-clone install -> swap target dir (and each sibling) for a git worktree -> copy DB -> set URL -> deps + build step per worktree
serve   -> wp server (PHP_CLI_SERVER_WORKERS) on the env's port
destroy -> refuse if run from inside; drop DB, remove every worktree, rm the clone, delete each branch if no unique commits
```

CoW makes the clone cheap despite size (a 2 GB install clones in ~13-17s, file-count
bound, near-zero disk until divergence). The source install and DB are never touched.

## Serving: `wp server`, and the worker requirement

WordPress has no `artisan serve`. Use **`wp server`** (WP-CLI's wrapper around PHP's
built-in server), which binds an explicit port, matching the slot scheme. **You
MUST run it with `PHP_CLI_SERVER_WORKERS` > 1.** `php -S` is single-threaded, and a
WordPress page load fires loopback HTTP requests (wp-cron, Site Health) to itself;
with one worker the first request waits on a second the server can't accept, and it
**deadlocks**. The script sets `PHP_CLI_SERVER_WORKERS=4` (CONFIG `WP_SERVER_WORKERS`).
This was the single hardest WP bug to find: serve appeared to "hang" while the
server was actually listening but unable to answer.

Herd still provides the toolchain (`php`, `composer`, `wp`, `mysql`) and runs the
shared MySQL. We just don't use Herd as the per-env web server (it's domain-based on
:80 and can't run N parallel copies of one site on distinct ports).

## Asset watchers: run them manually

The script deliberately does **not** auto-start the theme/plugin's `watch`/`dev`
script during `serve`. Real WP themes commonly wire `npm run watch` to **browser-sync**
(via `concurrently`), which: binds a fixed port (3000, collides across envs), tries
to open a browser, and **holds the parent process's stdout open so `serve` never
returns**. If you're actively editing CSS/JS, run the watcher yourself in the
worktree (`cd <install>/wp-content/themes/<theme> && npm run watch`), accepting that
browser-sync isn't suited to running unattended across parallel envs. A plain
compile step (`npm run compile:css`, `npm run bundle`, etc.) is fine to run on demand.

## Database and the site URL

The per-env DB is a copy of the site's DB (`wp db export | mysql import` into
`wp_<site>_<env>`), dropped on destroy. The site URL needs handling because WP
stores absolute URLs in the DB:

- **`WP_HOME`/`WP_SITEURL` override is always applied** (the env's wp-config gets
  `http://<WEB_HOST>:<port>`). This alone makes admin, login, AJAX, REST, and
  WP-derived asset URLs use the env. Tested: a **new upload** in the env writes to
  the env's `wp-content/uploads` and gets an env-port URL (fully isolated); existing
  attachments rendered via WP functions (`the_post_thumbnail`, etc.) also resolve to
  the env because WP recomputes them from `WP_SITEURL`.
- **`search-replace` is additionally run by default** (CONFIG `URL_MODE`), rewriting
  `http(s)://<host>` -> `http://<WEB_HOST>:<port>` across the DB. This fixes the one
  thing the override doesn't: **literal absolute URLs hard-coded in stored content**
  (page builders like Beaver Builder save these). It's cheap and **does not
  duplicate media** (the CoW clone already gave the env its own copy; search-replace
  only edits DB strings). Set `URL_MODE="override"` to skip it on very large DBs.

**`WEB_HOST` defaults to `localhost`, and should stay a name rather than a bare IP.**
Third-party services that restrict by origin or referrer — Font Awesome kits, Google
Maps and reCAPTCHA keys, Mapbox — allowlist **domains**, generally permit `localhost`
by default, and cannot allowlist an IP at all. Served on `127.0.0.1` they return 403
and their widgets silently fail to render, so visual QA in an env looks like the
branch broke the site rather than like an environment artifact. This applies only to
the **web** address; the `mysql -h 127.0.0.1` calls stay as they are, because a
hostname there makes the client switch from TCP to a unix socket. Note that an env
bakes its URL into wp-config and the DB at `create` time, so changing `WEB_HOST` only
affects envs created afterwards.

`--skip-columns=guid` is used (guids are stable identifiers, not display URLs). A
handful of URLs can remain after search-replace: the skipped guids, and
**escaped-slash JSON** (`http:\/\/host`) inside serialized page-builder data. If you
need those too, add a third pass replacing the escaped form. In practice the env
renders fine without it.

## `--skip-themes --skip-plugins` on DB-level wp calls

Any `wp` command that bootstraps WordPress (`db export`, `option get`,
`search-replace`) loads the site's plugins/theme, and a plugin that misbehaves in
CLI context (Beaver Builder, membership/SEO plugins, etc.) will **fatal and abort
provisioning**. The script runs those with `--skip-themes --skip-plugins` (they only
touch the DB, so nothing is lost), and guards the command substitution that reads
the URL so a failure can't kill `create` under `set -e`. `wp server` itself does
NOT skip plugins (it's serving the real site).

## Dependencies (themes/plugins have their own)

If the worktree has `composer.json` or `package.json`, the script ensures `vendor`
/ `node_modules` are present (CoW-clone from the source repo when available, else
`composer install` / `npm ci`). Composer additionally always reconciles to the
lockfile after the clone attempt — a bare "dir exists" check is fooled by repos
that track a partial vendor subset (some starters committed the phpcs toolchain
pre-gitignore), which materializes an incomplete vendor in a fresh worktree. The
script does **not** run a front-end "build" by default: WP repos use varied script
names (`build`/`bundle`/`compile:css`/...) and usually commit built assets. PHP
`vendor` matters most: themes/plugins autoload from it at runtime.

**If the repo gitignores its compiled assets** (e.g. compiled CSS at the theme
root), a fresh worktree has none and the env renders unstyled — and any e2e spec
that loads a compiled file from disk fails. Put the one-shot compile in the
per-project `project_after_worktree`, which runs with cwd = the worktree once
its deps are in place, once for the target repo and once per sibling; dispatch
on the install-relative path when they differ (tab-handbook's theme runs
`node_modules/.bin/sass scss:.`, its plugin `sass scss/style.scss:dist/style.css`).
Use `node_modules/.bin/<tool>` there, and also when you run a compile by hand in
Bash: a package-install gate hook denies any Bash call whose command line
contains `npx`, even `npx --no-install` (the hook reads the command line, not
the script body, so inside the script it is a matter of consistency).

## Working inside an env: bind with `EnterWorktree`, exit before teardown

The pre-PR workflow and most implementation work want the session's cwd inside
the env's theme/plugin worktree. Enter it with `EnterWorktree` (`path:` the
env's worktree). Because that path is outside `.claude/worktrees/`, the runtime
asks for approval once per env, by design (no allow rule suppresses it), and
the move takes effect immediately, so an unattended run continues without a
turn boundary. From then until `ExitWorktree` the session runs under the
runtime's worktree isolation (SKILL.md, "What `EnterWorktree` switches on"):

- Plain `wp <command>` from the worktree just works (WP-CLI walks up to the
  env's `wp-config.php`); single plain commands with literal arguments pass,
  and a `wp --path=<install> ...` form may point anywhere.
- Refused while bound: any `git -C` at the main checkout, command
  substitution, `$VAR` inside a chained command, heredocs with braces (a PHP
  file with closures, even into the worktree's own files), a heredoc chained
  with more commands, and git chained with anything but its own
  `add && commit`. Write/Edit bypass the vetting, so write PHP with them, and
  run git one step per call.
- The sibling worktree (the plugin beside a theme env, or the reverse) is
  fully usable by absolute path and `git -C <env sibling>`; it cannot become
  the session's cwd (adoption is limited to the launch repo's worktrees), so
  cwd-reading review skills see only the entered repo's diff. Hand them the
  sibling's diff explicitly.
- The binding survives compaction and an app restart and leaves no trace in
  the session's context. `ExitWorktree` with action `keep` lifts it at any
  point and is the first wrap-up step, before `destroy`.

The alternative, moving the session with the desktop app's
`mcp__ccd_directory__change_directory`, binds nothing and has none of that
friction, but a directory move only lands when the turn ends: a session that
keeps working never gets there, and calling the tool again only re-prompts.
It also costs a second folder prompt on the way out and two turn boundaries.
That is why binding is the default. To force the move-only flow instead, wire
`assets/agent-env-enter-worktree-gate.cjs` as a `PreToolUse` hook on
`EnterWorktree`: it refuses a path inside a WordPress env and names
`change_directory`, and `AGENT_ENV_ALLOW_ENTERWORKTREE=1` turns it back off.

Whichever way the session got in, three user-level hooks in
`~/.claude/settings.json` keep it off the main checkouts. All key on the
on-disk layout (the env's `<site>__<name>` install and the worktrees' gitdir
pointers), never on the session's launch directory, because the desktop app
relaunches a resumed session in whatever directory it stood in:

- `PreToolUse` Bash → `assets/agent-env-main-guard.cjs`: refuses `cd`,
  mutating `git -C`, `rm`, `cp`/`mv` and redirects aimed at any main checkout
  of the site (the sibling's included, which the runtime never covers), and
  `destroy` of the env the shell stands in. Read-only git and the lifecycle
  script's other commands pass.
- `PreToolUse` Edit|Write → `assets/worktree-edit-guard.cjs`: refuses file
  edits to any main checkout of the site.
- `SessionStart`, every source (no matcher) → `assets/agent-env-session-context.sh`:
  re-states the env, every main checkout, which one created it, the binding
  warning and the teardown rule, so the facts survive a compaction, a `/clear`
  or a restart (the same hook covers the generic engine's `.claude/worktrees/`
  envs).

Teardown runs from the main checkout that created the env: `ExitWorktree`
(action `keep`) first, then `scripts/agent-env-wp.sh destroy <name>` from
there, in the same turn. Both the script and the guard refuse a destroy from
inside the env (the `rm -rf` would take the shell's working directory with
it). An env's own `scripts/` copy is whatever its branch last committed, so
commit the script after changing it, or an env created afterwards still
carries the old copy.

## Sibling repos: theme + plugin in one env

A feature that spans both custom repos uses one env. Each repo's copy of the
script lists the other in `SIBLING_REPOS` (install-relative, e.g.
`wp-content/plugins/tab-handbook-plugin`), and `create` then swaps that repo's
CoW snapshot for a worktree of its main checkout on the same `worktree-<name>`
branch, from whatever that checkout has checked out (announced, with a warning
if it is dirty), installs its deps the same way and runs
`project_after_worktree` for it. `destroy` applies the dirty/unpushed guard to
every sibling before touching anything, removes every worktree, and deletes each
branch only when it carries no unique commits. Work done in a sibling worktree
lands on that repo's `worktree-<name>` branch: push it and open its PR from there.

The list is explicit on purpose: vendored plugins carry `.git` directories too,
so detection would branch third-party code. Everything not listed stays a CoW
snapshot, and a sibling commit that lands on `main` after `create` is not in the
env until you merge `main` into the env's branch of that repo.

**Stop anything running FROM a sibling worktree before `destroy`**, in
particular a plugin's wp-env (`node_modules/.bin/wp-env stop`): Docker holds
mounts of the path `destroy` is about to delete.

## Other notes

- **Run from the repo's main checkout**; the script walks up to `wp-config.php` to
  find the install and computes the repo's `wp-content/...` path. It also defaults
  the worktree base to the repo's current branch (WP repos are often on a feature
  branch, not `main`).
- **Ports come from one pool per `ENV_PARENT`** (`<ENV_PARENT>/.wp-slots/`): a slot
  is taken when the registry says so or an existing env's `wp-config.php` declares
  its port, so repos that share an `ENV_PARENT` need no `PORT_BASE` coordination.
- **Env clones live outside Herd-parked paths** (CONFIG `ENV_PARENT`) so Herd
  doesn't try to serve them; we serve via `wp server`.
- One port per env by default; if a repo genuinely uses a port-bound dev server you
  run manually, give it a distinct port per env.

## Dogfooded (validation notes)

Two repos exercised end to end (create / serve / stop / destroy), source + DB left
untouched:
- **Theme, http, composer+npm** (tough-bible-stuff-theme): green; serve 2s, home 200.
- **Plugin, https, page-builder (Beaver Builder), 2.1 GB** (spendthrift-tickets-plugin):
  green; plugin-rel path, https->http search-replace, composer+npm, serve 2s, home 200.

Also available as targets: excel-engineering/firstscribe (no build, 1.8 GB, https) and
tab-handbook (theme + plugin, http).
