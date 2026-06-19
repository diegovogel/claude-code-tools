# Agent environments for Laravel (worked example)

A filled-in **per-project section** for a Laravel app, plus the decisions behind
it. The engine in `assets/agent-env.sh` is unchanged and stack-agnostic; this is
just what goes between its `PER-PROJECT SECTION` markers. Read
[`stacks.md`](stacks.md) first for the generic framework; this file is the
Laravel-specific fill-in. The same shape applies to any PHP/Composer app.

## Serve with `php artisan serve`, not Herd/Valet

Laravel devs usually run sites through **Herd** (or Valet) at `<name>.test` on
port 80, via directory parking + a local DNS/nginx layer. That model is great for
normal dev but wrong for agent envs: it's **domain-based, not port-based**, serves
on a shared :80, and can't run N parallel copies of the *same* app on distinct
ports. The engine is built on deterministic per-slot ports.

So: serve each env with **`php artisan serve --host=127.0.0.1 --port=<slot port>`**.
It's built into Laravel (no dependency), binds an explicit port, and matches the
slot scheme exactly. **Keep Herd as the provider** of the toolchain, it puts
`php`, `composer`, `mysql`, and `redis` on `PATH` and runs the shared MySQL/Redis
services. You use Herd's binaries and services; you just don't use Herd as the
per-env web server.

(If the project ships a `composer dev` script, it runs `artisan serve` + queue +
Vite on *fixed* ports via `concurrently`, so it WILL collide between envs. Treat
it like `npm run dev`: name it in `MAIN_DEV_CMD` and guard it.)

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

## The per-project section

Paste this between the engine's `PER-PROJECT SECTION` markers and adjust the
CONFIG. It covers SQLite and MySQL via one `DB_STRATEGY` switch.

```bash
# --- CONFIG -----------------------------------------------------------------
WORKTREES_SUBDIR=".claude/worktrees"
CANONICAL_BRANCH_PREFIX="worktree-"
PORT_BASE=18000          # pick a base unused by other projects you run in parallel
PORT_STRIDE=10
PORTS_PER_ENV=2          # web (artisan serve) + Vite. Set 1 if the app has no
                         # front end, or for Laravel Mix (see Variants below).
MAIN_DEV_CMD="php artisan serve / composer dev"

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

# --- launch: artisan serve (web) + Vite (assets) + queue worker (if not sync)
project_start_servers() {
  local env="$1" web_port="$2" vite_port="${3:-}"
  cd "$env"
  php artisan serve --host=127.0.0.1 --port="$web_port" >>logs/web.log 2>&1 &
  echo $! >.agent-env/web.pid
  if [[ -f package.json && -n "$vite_port" ]]; then
    npm run dev -- --port="$vite_port" --host 127.0.0.1 >>logs/vite.log 2>&1 &
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

- **Cached config shadows `.env`.** If `bootstrap/cache/config.php` exists (from
  `config:cache`), it overrides the env's `.env` ports/DB. `project_after_provision`
  runs `config:clear`. (A fresh worktree usually has no cached config, since
  `bootstrap/cache/` is gitignored and not CoW-cloned, but clear it anyway.)
- **`APP_KEY` consistency.** Copying main's `.env` carries its `APP_KEY`, so
  encrypted/session data stays compatible. Only generate a key when seeding from
  `.env.example` (the guard `grep -q '^APP_KEY=base64:'` handles this).
- **Herd MySQL is TCP-only here.** Connect via `-h 127.0.0.1 -P 3306`, the default
  socket `/tmp/mysql.sock` isn't where Herd puts it.
- **`migrate --seed` is for a *fresh* per-env DB.** That's the case here (new
  schema / new sqlite file). Don't point an env at a shared/populated DB.
- **SQLite path is pinned per env** (`DB_DATABASE=database/database.sqlite` in
  `project_env_port_lines`). Without it, the env's DB file follows the app's
  config: most apps use `database_path('database.sqlite')` (env-local, fine), but
  some use `storage_path('database.sqlite')` (e.g. klog) and, worse, an absolute
  `DB_DATABASE` in the base `.env` would make every env AND main share one file.
  Pinning a known relative path guarantees isolation regardless. Confirmed live:
  klog's tables landed in the env's own `database/database.sqlite`, main untouched.
- **`.env` and `database/database.sqlite` are gitignored** (so they're never in a
  fresh worktree, which is why we create them) and the config file must stay
  gitignored or provision's managed block reads as a dirty worktree.
- **A front-end build that COMMITS its output dirties the worktree on serve.**
  Vite's `public/build` is gitignored, so serving leaves the worktree clean. Some
  Laravel Mix setups commit the compiled `public/css`, `public/js`, and
  `mix-manifest.json`; running the watcher then shows those as modified, so a plain
  `destroy` refuses (uncommitted changes) and you need `destroy --force` (the dirt
  is build artifacts, not real work). Best fix: gitignore the build output.
  Confirmed live, bluehorseentries (gitignored, stayed clean) vs hk-lpsignals
  (tracked, went dirty).
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
  then optionally `php artisan migrate --force` to top up. Confirmed live with
  hk-lpsignals (a `FiguresCalculate` command queries `tracks` in its constructor).

## Dogfooded (validation notes)

Six repos exercised end to end (create / serve / stop / destroy), each left pristine:
- **SQLite + Vite** (system-2-data-cruncher, PEC-report-data-extractor): green.
- **SQLite + Vite, app points the DB at `storage_path`** (klog): green; motivated
  the per-env `DB_DATABASE` pin above (tables landed in the env's own file).
- **MySQL + Redis + Mix** (bluehorseentries): green; per-env schema created + dropped.
- **MySQL + Mix + Inertia, sync queue** (carriage-house-printery): green; sync queue
  correctly starts no worker; created from its feature branch (pass the base ref).
- **MySQL + Mix that commits its built assets** (hk-lpsignals): the watcher dirties
  tracked files, so `destroy --force`; also surfaced the DB-at-boot caveat above.

Not yet run: **mbrp-main-app** (no `.env`/vendor/node_modules, no front end) would
exercise the cold-start path (`composer install` + `.env.example` + `key:generate`).
