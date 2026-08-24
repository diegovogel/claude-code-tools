# Agent environments for WordPress (theme / plugin repos)

WordPress is the documented exception to the engine's "the git repo is the
runnable project" model. Here the repo is a **theme or plugin nested in
`wp-content/`**, but a runnable env needs the **whole WordPress install**. So WP
gets its own script, [`assets/agent-env-wp.sh`](../assets/agent-env-wp.sh), which
reuses the engine's primitives (slot/port registry, the `unique_commits` destroy
guard, pid/health machinery, CoW clone) but with a WP-specific flow.

Use it the same way you'd be anchored: **run it from inside the theme/plugin
repo**; it finds the enclosing WP install automatically.

## The model

An env is:
- a **copy-on-write clone of the entire WP install** (core + all of wp-content +
  uploads), placed outside Herd's parked dirs (`~/WebDev/Sites/.wp-agent-envs/`
  by default) so it isn't auto-served as a `.test` domain;
- with the **target theme/plugin replaced by a git worktree** of your repo (on
  branch `worktree-<name>`), nested at its normal `wp-content/...` path;
- its **own database** (`wp_<site>_<env>`, copied from the site), and
- its **own port**, served with `wp server`.

```
create  -> CoW-clone install -> swap target dir for a git worktree -> copy DB -> set URL -> deps
serve   -> wp server (PHP_CLI_SERVER_WORKERS) on the env's port
destroy -> drop DB, remove worktree, rm the clone, delete branch if no unique commits
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
that loads a compiled file from disk fails. Add a one-shot compile to the create
flow's per-project section (tab-handbook does `node_modules/.bin/sass scss:.`
after npm deps).

## Sibling-repo work in one env (theme + plugin)

A feature that spans both custom repos (e.g. tab-handbook's theme + plugin) can use
one env: the engine manages the **target** repo's worktree, and you hand-create a
second worktree for the sibling inside the clone at its normal path
(`git -C <main-sibling-checkout> worktree add <env>/wp-content/plugins/<plugin> -b <branch>`).
The env then serves both branches together. Two consequences the engine does NOT
handle:

- **`destroy` only reclaims its own repo's side.** It deletes the clone directory
  (taking the sibling worktree's files with it) but knows nothing about the sibling
  repo's git state, which is left with a dangling "prunable" worktree registration
  and the feature branch. Finish teardown from the sibling's MAIN checkout:
  `git worktree prune`, then `git branch -d <branch>`.
- **Stop anything running FROM the sibling worktree before `destroy`.** In
  particular a plugin's wp-env (`node_modules/.bin/wp-env stop`): Docker holds
  mounts of the path `destroy` is about to delete.

## Other notes

- **Run from the repo**; the script walks up to `wp-config.php` to find the install
  and computes the repo's `wp-content/...` path. It also defaults the worktree base
  to the repo's current branch (WP repos are often on a feature branch, not `main`).
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
