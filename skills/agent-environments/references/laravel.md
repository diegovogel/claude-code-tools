# Agent environments for Laravel (worked example)

A filled-in **project config** (`~/.claude/agent-environments/<project>/project.sh`)
for a Laravel app, plus the decisions behind it. The engine in
`assets/agent-env.sh` is unchanged and stack-agnostic; this is just what it
sources for the project. Read
[`stacks.md`](stacks.md) first for the generic framework; this file is the
Laravel-specific fill-in. The same shape applies to any PHP/Composer app.

## Serve with `php artisan serve`, not Herd/Valet

Laravel devs usually run sites through **Herd** (or Valet) at `<name>.test`.
Since Herd 2.0 it can serve each git worktree as well, at `<branch>.<site>.test`
(its "workspaces"), so the old reason for avoiding it (one copy of a site, on a
shared :80) is gone. Envs still serve with
**`php artisan serve --host=127.0.0.1 --port=<slot port>`**, because letting Herd
serve an env costs more than it buys today: adoption edits the env's `.env`, a
Herd-served env gets a Herd-started `php artisan dev` stack whenever its Vite is
down, and Herd's own delete and merge bypass the guarded teardown (measurements
and what a Herd-served flavor would need:
[Herd 2.0 workspaces](#herd-20-workspaces)). `artisan serve`
is built into Laravel, binds the slot's explicit port, and fits the engine's
port-based slots, `serve`/`stop` and health checks. **Keep Herd as the provider**
of the toolchain, it puts
`php`, `composer`, `mysql`, and `redis` on `PATH` and runs the shared MySQL/Redis
services. You use Herd's binaries and services; you just don't use Herd as the
per-env web server.

(If the project ships a `composer dev` script, it runs `artisan serve` + queue +
Vite on *fixed* ports via `concurrently`, so it WILL collide between envs. Treat
it like `npm run dev`: name it in `MAIN_DEV_CMD` and guard it. Newer skeletons'
`composer dev` runs `@php artisan dev` instead (check composer.json), and
`php artisan dev` itself has no guard; see the gotcha below.)

## Herd 2.0 workspaces

Measured 2026-10-21 on Herd 2.0.0 with throwaway worktrees of a SQLite Laravel 13.35 app,
and cross-checked against the Herd CLI source (`herd.phar` in Herd.app's
Resources: `cli/Valet/Workspace.php`, `GitWorktrees.php`,
`WorkspaceDatabase.php`, `Drivers/LaravelValetDriver.php`). Re-check before
building on it; Herd moves fast.

- **Discovery.** Herd lists every linked worktree of a site's repo, wherever it
  lives, as an unserved workspace (`herd workspaces --site=<site>`). The host is
  the sanitized branch plus the site, `worktree-<name>.<site>.test` for an env.
  The label is cut to `54 - len(site)` characters, so long env names sharing a
  prefix map to one host.
- **Adoption.** A GET of that host returns a 503 setup page whose script POSTs
  to Herd's API (`127.0.0.1:2304/workspaces/serve`), which adopts the worktree
  in shared-database mode with no prompt. curl alone changes nothing; a browser
  or Playwright adopts it. `herd workspace` run inside a worktree adopts it too,
  using `herd.yml`'s database default.
- **What adoption writes.** It never replaces an existing `.env`. It rewrites
  the FIRST existing `APP_URL` line (it never adds one), and the first
  `SESSION_DOMAIN` / `SANCTUM_STATEFUL_DOMAINS` line when it names the parent.
  Only `herd.yml` `workspaces.env` keys and a shared-SQLite `DB_DATABASE` are
  appended when missing, at the very end of the file. The managed block still
  wins only because an env's copied base `.env` has its own `APP_URL` line
  above it (Laravel reads the last duplicate); without one, Herd rewrites the
  block's `APP_URL`. With SQLite in shared mode, a worktree whose relative
  database file doesn't exist yet gets `DB_DATABASE=<main's file, absolute>`;
  a bare worktree adopted that way had Herd's first probe write a session row
  into main's database. Herd copies main's `.env` (plain copy) only when the
  env has none, and `vendor/` / `node_modules/` (APFS `cp -c -R`) only when
  absent and the first lockfile matches main's byte for byte. It copies main's
  `public/build` into an env with neither `public/build` nor `public/hot`, so
  the env can render main's stale assets while its Vite is down. It deletes
  `public/hot`, runs `artisan config:clear && route:clear`, writes
  `.herd-workspace.json` (excluded through the repo's shared
  `.git/info/exclude`; the marker outlives an unlink), links the host without
  `.test` (`Sites/worktree-<name>.<site>`), and for a secured parent issues a
  certificate and restarts nginx.
- **Automatic dev server.** With Herd Studio on (the default), a GET of a
  Herd-served Laravel site whose Vite isn't live asks Herd to start the site's
  dev stack: `php artisan dev --json` when DevCommand has `--json` (13.25+) and
  `node_modules/@laravel/multiplex` exists (`artisan serve` on :8000 or
  `SERVER_PORT`, `queue:listen`, pail, and the package.json `dev` script, which
  the guard refuses), the package.json dev script otherwise. It skips a site
  whose `public/hot` points at a live server, so an env under `serve` is left
  alone, but only while `public/hot` exists: adoption deletes it, so an env
  adopted while under `serve` loses HMR (or 500s on `@vite` with no build) and
  becomes eligible for the boot until `stop` and `serve` restart Vite. To stop
  a Herd-started stack in an adopted env you are keeping (`destroy` does this
  itself), name the workspace's Sites name (the
  marker's `site`, no `.test`): `herd processes --site=<site> --json` to
  confirm, then `herd processes:stop dev --site=<site>`. Never pass the parent
  site's name, and never a path inside an unadopted env: both resolve to the
  main checkout and stop the human's stack.
- **Serving.** Herd's PHP-FPM answered 4 concurrent 1.5 s requests in 2.4 s on 4
  workers; `artisan serve` took 6.1 s on one. Insights captured every
  Herd-served request and none of `artisan serve`'s (its `php -S` runs from
  `public/`, where Herd's injector bails). An HTTPS workspace page loading Vite
  from `http://127.0.0.1:<port>` worked in Chromium, HMR included, because
  loopback is exempt from mixed-content blocking. Safari not checked.
- **Teardown.** `herd workspace:delete` runs `herd.yml`'s `before_delete` hook,
  unlinks and unsecures, drops a non-shared database, then runs
  `git worktree remove --force` (no dirty or unpushed check; a test worktree's
  uncommitted files were deleted) unless `--keep-files`. It never deletes the
  branch. When a worktree is removed behind Herd's back, the next
  `herd workspaces` prunes the registry record and certificate but leaves a
  dangling `Sites/worktree-<name>.<site>` symlink, which `herd unlink` reports
  removing and doesn't. Until something prunes the record, re-creating an env
  at the same path inherits the stale record and link.
- **Lookup by name.** `herd workspace:delete <arg>` acts on the first registry
  record whose `name` or `site` matches, and `name` is the sanitized branch
  (`worktree-<name>`), which repeats across repos. Only the `site` (host
  without `.test`) is unique.
- **Merge.** `herd workspace:merge` fast-forwards the base branch recorded at
  adoption (whatever the main checkout had checked out then), or falls back to
  `git merge` inside the main checkout's working tree; `--push` pushes it.
  Denied for Claude by `Bash(herd workspace:merge *)` in
  `~/.claude/settings.json`.
- **What the engine does about adoption.** The registry,
  `~/Library/Application Support/Herd/config/valet/workspaces.json`, holds
  only adopted (served) workspaces, so the engine reads it with `jq`, matching
  the env's path. `list` prints an "adopted by Herd" line under such an env.
  `destroy` runs `herd processes:stop <p> --site=<site>` for dev, vite, pail
  and queue, then `herd workspace:delete <site> --keep-files --force`, all from
  the main checkout and before its own guarded removal. It runs `herd` with
  Herd's bin dir appended to PATH, because the `herd` wrapper exits 0 having
  done nothing when it can't find Herd's php (a git hook or GUI client), and it
  judges the unlink by the registry, not the exit code. When the record
  survives (Herd not running), it removes the env's `Sites/<site>` link once
  the worktree is gone (only if it dangles and points at the env), then runs
  `herd workspaces --all --json`, whose orphan pruning needs no running app,
  and warns only if the record is still there. Live-checked on Herd 2.0.0; the
  engine test covers each branch with a fake registry and a stub `herd`.

**A Herd-served env flavor** (not built) would trade `artisan serve` for FPM
concurrency, Herd's php.ini and Insights. It would need: the managed block's
`APP_URL` set to the workspace URL; `project_health_urls` probing that URL;
Herd's automatic dev server kept off for envs (Herd Studio's per-site toggle;
`SERVER_PORT=<web port>` in the managed block would at least keep its server
off main's :8000, and in this flavor the env runs no `artisan serve` of its own
to collide with). `destroy` already unlinks an adopted env, so teardown needs
nothing new.

## Database isolation depends on the engine

| Engine | Isolation | How |
|---|---|---|
| **SQLite** (modern Laravel default) | free, per-worktree | the env gets its own `database/database.sqlite` (path pinned via `DB_DATABASE`, see gotchas), `touch` + `migrate`. Fully isolated, no shared server. |
| **MySQL** | per-env schema on the shared server | Herd's MySQL listens on TCP `127.0.0.1:3306` (not the default `/tmp/mysql.sock`). Create `<base>_<env>`, migrate, and `DROP` it on destroy. |
| **Postgres** | per-env database on the shared server | Connect via `127.0.0.1:5432`. `CREATE DATABASE <base>_<env>` (or `… TEMPLATE <base>` to clone the populated dev DB — far faster than dump/restore, but the source must have no open connections), migrate, and `DROP` it on destroy. |
| **Redis** (queue/cache) | per-env key namespace | shared server; set a per-env `REDIS_PREFIX` so envs can't read each other's cache/queue. |

SQLite is the easy, fully-isolated case (and the L11+ default). MySQL/Postgres/Redis
are shared servers, so isolate the *logical* unit (schema / database / key prefix),
not the server. Postgres mirrors the MySQL branch below — add a `pgsql` arm to the
create/drop hooks (`psql`, or `createdb`/`dropdb`); reach for `CREATE DATABASE …
TEMPLATE` when an env needs the populated dev data instead of fresh seeds.

## The project config

This is the content of `~/.claude/agent-environments/<project>/project.sh`
(start from `assets/project.example.sh`, replace its body with this, adjust the
CONFIG). It covers SQLite and MySQL via one `DB_STRATEGY` switch.

```bash
# --- CONFIG -----------------------------------------------------------------
WORKTREES_SUBDIR=".claude/worktrees"
CANONICAL_BRANCH_PREFIX="worktree-"
PORT_BASE=18000          # pick a base unused by other projects you run in parallel
PORT_STRIDE=10
PORTS_PER_ENV=2          # web (artisan serve) + Vite. Set 1 if the app has no
                         # front end, or for Laravel Mix (see Variants below).
MAIN_DEV_CMD="composer dev / php artisan dev"  # php artisan dev (Laravel 13.16+) has no guard

# DB isolation for THIS project: "sqlite" or "mysql".
DB_STRATEGY="sqlite"
DB_BASENAME="myapp"      # mysql only: per-env DB = <DB_BASENAME>_<env>
DB_ADMIN_USER="root"     # mysql only: a user that can CREATE/DROP DATABASE (Herd: root, no pw)

db_token() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'; }   # env name -> SQL-safe token

# --- seed: vendor (Composer) + node_modules (CoW), reconcile against lockfiles
project_seed_env_files() {
  local main="$1" env="$2"
  # Composer needs private-registry creds (e.g. Flux Pro) for any install, and
  # auth.json is git-ignored so the worktree never has it — seed it before
  # composer runs, or installs 401. Read-only creds, safe to copy.
  [[ -f "$main/auth.json" && ! -f "$env/auth.json" ]] && cp "$main/auth.json" "$env/auth.json"
  if [[ ! -d "$env/vendor" ]]; then
    if [[ -d "$main/vendor" ]] && clone_dir "$main/vendor" "$env/vendor"; then :; else
      rm -rf "$env/vendor"; ( cd "$env" && composer install --no-interaction --no-progress )
    fi
  fi
  if ! cmp -s "$main/composer.lock" "$env/composer.lock" 2>/dev/null; then
    ( cd "$env" && composer install --no-interaction --no-progress )
  fi
  if [[ -f "$env/package.json" && ! -d "$env/node_modules" ]]; then
    if [[ -d "$main/node_modules" ]] && clone_dir "$main/node_modules" "$env/node_modules"; then :; else
      rm -rf "$env/node_modules"; ( cd "$env" && npm ci )
    fi
  fi
  # The engine already seeds .env (main's, else .env.example). Don't copy
  # database/database.sqlite (gitignored; created fresh in after_provision).
}

# --- config lines: APP_URL/port, per-env DB name (mysql), per-env Redis prefix
project_env_port_lines() {
  local name="$1" slot="$2"; shift 2
  local web_port="$1" vite_port="${2:-}"
  printf 'APP_URL=http://127.0.0.1:%s\n' "$web_port"
  printf 'APP_PORT=%s\n' "$web_port"
  if [[ "$DB_STRATEGY" == "mysql" ]]; then
    printf 'DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=3306\n'
    printf 'DB_DATABASE=%s_%s\n' "$DB_BASENAME" "$(db_token "$name")"
  else
    # Pin sqlite to a known env-local path so isolation holds regardless of the
    # app's configured default (some apps use storage_path, not database_path) or
    # an absolute DB_DATABASE in the base .env (which would make envs share one
    # file). Relative => resolves against the process CWD, which is the env, since
    # provision/serve/queue all run there.
    printf 'DB_CONNECTION=sqlite\nDB_DATABASE=database/database.sqlite\n'
  fi
  printf 'REDIS_PREFIX=%s_\n' "$(db_token "$name")"   # harmless if Redis unused
}

# Herd serves the main checkout at <name>.test (:80), not a fixed dev port, so
# there's no fixed-address takeover. Echo nothing.
project_main_ports() { :; }

# Herd's PHP finds its php.ini through HERD_PHP_<ver>_INI_SCAN_DIR, which the
# user's shell exports and an agent's Bash session may lack. Without it the
# served PHP loads no ini at all and runs on built-in defaults (2M uploads, 8M
# POST bodies) instead of Herd's, so file uploads over 2 MB fail in an env that
# an agent started while the same code works on the Herd site. `artisan serve`
# passes the variable through to its `php -S` child. No-op without Herd, or
# when the variable is already set.
project_herd_php_ini() {
  local version var dir
  version="$(php -r 'echo PHP_MAJOR_VERSION.PHP_MINOR_VERSION;')"
  var="HERD_PHP_${version}_INI_SCAN_DIR"
  dir="$HOME/Library/Application Support/Herd/config/php/$version/"
  if [[ -z "${!var:-}" && -d "$dir" ]]; then
    export "$var=$dir"
  fi
}

# --- launch: artisan serve (web) + Vite (assets) + queue worker (if not sync)
project_start_servers() {
  local env="$1" web_port="$2" vite_port="${3:-}"
  cd "$env"
  project_herd_php_ini
  php artisan serve --host=127.0.0.1 --port="$web_port" >>logs/web.log 2>&1 &
  echo $! >.agent-env/web.pid
  if [[ -f package.json && -n "$vite_port" ]]; then
    # Call vite directly, not `npm run dev`: that script carries the in-env
    # guard (setup step 4) and exits 1 here, which would leave the env without
    # Vite while serve still reports "up" (only the web URL is health-checked).
    npx vite --port="$vite_port" --host 127.0.0.1 >>logs/vite.log 2>&1 &
    echo $! >.agent-env/vite.pid
  fi
  if grep -qE '^QUEUE_CONNECTION=(database|redis|beanstalkd|sqs)' .env 2>/dev/null; then
    php artisan queue:work --tries=1 >>logs/queue.log 2>&1 &
    echo $! >.agent-env/queue.pid
  fi
}

# artisan serve returns 200 on / once booted; that's the readiness signal.
project_health_urls() {
  local web_port="$1"
  echo "web|http://127.0.0.1:$web_port/|60"
}

# --- after provision: app key, clear cached config, create+migrate the DB
project_after_provision() {
  local env="$1" name="$2" slot="$3"
  cd "$env"
  grep -q '^APP_KEY=base64:' .env || php artisan key:generate --force >/dev/null 2>&1 || true
  php artisan config:clear >/dev/null 2>&1 || true
  case "$DB_STRATEGY" in
    sqlite) mkdir -p database; touch database/database.sqlite ;;
    mysql)
      local db="${DB_BASENAME}_$(db_token "$name")"
      mysql -u "$DB_ADMIN_USER" -h 127.0.0.1 -P 3306 \
        -e "CREATE DATABASE IF NOT EXISTS \`$db\`" 2>/dev/null \
        || warn "could not create MySQL db $db" ;;
  esac
  php artisan migrate --force --seed >>logs/provision.log 2>&1 \
    || warn "migrate failed; see $env/logs/provision.log"
}

# --- on destroy: drop the per-env MySQL DB (SQLite goes away with the worktree)
project_pre_destroy() {
  local env="$1" name="$2" slot="$3"
  if [[ "$DB_STRATEGY" == "mysql" ]]; then
    local tok; tok="$(db_token "$name")"
    local db="${DB_BASENAME}_${tok}"
    # Refuse to DROP unless the target is unmistakably this env's DB. A bad $name
    # could otherwise resolve $db to the shared dev/test DB, and the drop is final.
    if [[ -z "$tok" || "$db" == "$DB_BASENAME" || "$db" == *_testing ]]; then
      warn "refusing to drop '$db': not a recognizable per-env database"; return
    fi
    mysql -u "$DB_ADMIN_USER" -h 127.0.0.1 -P 3306 \
      -e "DROP DATABASE IF EXISTS \`$db\`" 2>/dev/null || warn "could not drop MySQL db $db"
  fi
}
```

## Variants

- **No front end** (API-only / no `package.json`): set `PORTS_PER_ENV=1`. The
  Vite block in `project_start_servers` self-skips (it checks for `package.json`).
- **Laravel Mix** (older apps, `webpack.mix.js`, npm scripts `dev/watch/hot`):
  Mix's `hot` HMR binds a fixed port (8080) that can't be isolated per env. Set
  `PORTS_PER_ENV=1` and replace the Vite line with a compile-on-change watcher:
  `npm run watch >>logs/assets.log 2>&1 &` (writes built assets to disk, no port).
- **Not-yet-set-up project** (no `.env`, no `vendor/`, no `node_modules`): nothing
  extra needed. `project_seed_env_files` runs `composer install` / `npm ci` when
  the CoW source is missing, the engine seeds `.env` from `.env.example`, and
  `project_after_provision` runs `key:generate` + `migrate`. This is the path that
  most exercises the setup, good first dogfood target.
- **Octane / Horizon**: none of the sampled apps run Octane. If a project uses
  Octane, swap `artisan serve` for `artisan octane:start --port=$web_port`. Horizon
  is heavier than needed for an isolated dev env, `queue:work` against the env's
  own DB/Redis-prefix is enough; only start Horizon if you're specifically testing
  it.

## Gotchas (Laravel-specific)

- **Start Vite directly in `project_start_servers`, never via `npm run dev`.**
  Setup step 4 puts `./scripts/agent-env.sh guard` in front of `npm run dev`, so
  a config that launches Vite with `npm run dev -- --port=...` gets the guard's
  refusal in `logs/vite.log` and no Vite at all, while `serve` still reports the
  env up because only the web URL is health-checked. Use
  `npx vite --port="$vite_port" --host 127.0.0.1` (as above). Hit converting
  an app on 2026-09-18: its config used `npm run dev` and the guard was added
  to `package.json` in the same conversion.
- **Cached config shadows `.env`.** If `bootstrap/cache/config.php` exists (from
  `config:cache`), it overrides the env's `.env` ports/DB. `project_after_provision`
  runs `config:clear`. (A fresh worktree usually has no cached config, since
  `bootstrap/cache/` is gitignored and not CoW-cloned, but clear it anyway.)
- **`APP_KEY` consistency.** Copying main's `.env` carries its `APP_KEY`, so
  encrypted/session data stays compatible. Only generate a key when seeding from
  `.env.example` (the guard `grep -q '^APP_KEY=base64:'` handles this).
- **Herd MySQL is TCP-only here.** Connect via `-h 127.0.0.1 -P 3306`, the default
  socket `/tmp/mysql.sock` isn't where Herd puts it.
- **Herd's php.ini is not always loaded from an agent's shell.** Herd's `php`
  locates its ini via `HERD_PHP_<ver>_INI_SCAN_DIR`, exported by the user's
  `~/.zshrc`; whether Claude Code's Bash has it depends on how that shell was
  started (absent on 2026-09-14, present on 2026-10-21). A server started
  without it runs on PHP's built-in limits (`upload_max_filesize=2M`), so uploads
  over 2 MB fail in the env but work on the Herd site, which looks like an app
  bug. `project_herd_php_ini` (above) exports the variable before `serve` and is
  a no-op when it's already set; check with
  `php -r 'echo ini_get("upload_max_filesize");'` from the same shell.
- **`php artisan dev` gets past the guard (Laravel 13.16+).** The guard is the
  first step of `composer dev` and `npm run dev`; `php artisan dev` is neither,
  whatever `composer dev` runs (newer skeletons' `composer dev` calls it, older
  ones run their own `concurrently` line). Run directly, by an agent or by
  Herd's automatic dev server, it starts `artisan serve` on :8000 (main's dev
  port), `queue:listen` and pail, and only its Vite child (the guarded
  `npm run dev`) is refused. `MAIN_DEV_CMD` only feeds the engine's messages,
  so name it there and in the project CLAUDE.md rule: the rule is the only
  protection. `artisan serve` takes its default port from `SERVER_PORT` in
  `.env` (verified), so `SERVER_PORT=<web port>` in the managed block would
  keep such a server off main's :8000. The cost: with a port set it never
  falls back to another, so a stray server started while `serve` is down holds
  the slot's port and the next `serve` fails with port in use.
- **`migrate --seed` is for a *fresh* per-env DB.** That's the case here (new
  schema / new sqlite file). Don't point an env at a shared/populated DB.
- **A green in-env test run does not prove the per-env DB.** `phpunit.xml` usually
  pins tests to `DB_CONNECTION=sqlite` / `DB_DATABASE=:memory:`, so `run <name> -- php
  artisan test` never touches the MySQL schema the env was given. Prove the DB with a
  non-test command instead:
  `run <name> -- php artisan tinker --execute='echo DB::connection()->getDatabaseName();'`
  must print `<base>_<env token>`. Seen while converting a MySQL app on 2026-09-18.
- **SQLite path is pinned per env** (`DB_DATABASE=database/database.sqlite` in
  `project_env_port_lines`). Without it, the env's DB file follows the app's
  config: most apps use `database_path('database.sqlite')` (env-local, fine), but
  some use `storage_path('database.sqlite')` and, worse, an absolute
  `DB_DATABASE` in the base `.env` would make every env AND main share one file.
  Pinning a known relative path guarantees isolation regardless. Confirmed live on
  a `storage_path` app: its tables landed in the env's own
  `database/database.sqlite`, main untouched.
- **`.env` and `database/database.sqlite` are gitignored** (so they're never in a
  fresh worktree, which is why we create them) and the config file must stay
  gitignored or provision's managed block reads as a dirty worktree.
- **A front-end build that COMMITS its output dirties the worktree on serve.**
  Vite's `public/build` is gitignored, so serving leaves the worktree clean. Some
  Laravel Mix setups commit the compiled `public/css`, `public/js`, and
  `mix-manifest.json`; running the watcher then shows those as modified, so a plain
  `destroy` refuses (uncommitted changes) and you need `destroy --force` (the dirt
  is build artifacts, not real work). Best fix: gitignore the build output.
  Confirmed live: an app with the output gitignored stayed clean, one with it
  tracked went dirty.
- **Laravel's default `package.json` has no `name` field**, so npm names
  `package-lock.json` after the worktree directory; committing that from an env and
  merging it corrupts main's lockfile. Add an explicit `"name"` to `package.json`
  once. (The general rule and which package managers drift: [`stacks.md`](stacks.md)
  gotchas.)
- **Apps that hit the DB during `artisan` boot can't migrate a fresh per-env DB.**
  If a command constructor or a provider's `boot()` runs a query (e.g.
  `Track::where(...)->get()` in a command's `__construct`), `artisan` instantiates
  it on every invocation, so `migrate` (and `serve`) crash against an empty schema
  with "table ... doesn't exist" before any table can be created. The app works
  normally only because its real DB is already populated. This is an app
  anti-pattern the per-env DB surfaces, not a skill bug. Options: fix the app to not
  query at boot; or, for apps that genuinely need existing data, seed the per-env DB
  from the main one in `project_after_provision` instead of migrating from scratch:
  `mysqldump -u root -h127.0.0.1 "$DB_BASENAME" | mysql -u root -h127.0.0.1 "${DB_BASENAME}_$(db_token "$name")"`
  then optionally `php artisan migrate --force` to top up. Confirmed live with an
  app whose console command queries a table in its constructor.

## Dogfooded (validation notes)

Six repos exercised end to end (create / serve / stop / destroy), each left pristine:
- **SQLite + Vite** (two apps): green.
- **SQLite + Vite, app points the DB at `storage_path`**: green; motivated
  the per-env `DB_DATABASE` pin above (tables landed in the env's own file).
- **MySQL + Redis + Mix**: green; per-env schema created + dropped.
- **MySQL + Mix + Inertia, sync queue**: green; sync queue correctly starts no
  worker; created from its feature branch (pass the base ref).
- **MySQL + Mix that commits its built assets**: the watcher dirties tracked
  files, so `destroy --force`; also surfaced the DB-at-boot caveat above.

Not yet run: an app with no `.env`/vendor/node_modules and no front end would
exercise the cold-start path (`composer install` + `.env.example` + `key:generate`).
