#!/usr/bin/env bash
#
# agent-env-wp.sh: isolated parallel environments for coding agents working on a
# WordPress theme or plugin.
#
# WordPress breaks the generic engine's assumption that "the git repo IS the
# runnable project": here the repo is a theme/plugin nested in wp-content/, but a
# runnable env needs the WHOLE install. So an env is a copy-on-write clone of the
# entire WP install, with the target theme/plugin swapped for a git worktree of
# your repo (on the env branch), its own database, and its own port (wp server).
#
# Run this from inside the theme/plugin repo (the same place your session is
# anchored). It finds the enclosing WP install automatically.
#
# Usage:
#   agent-env-wp.sh create <name> [base-ref]   # clone install + worktree + DB + config
#   agent-env-wp.sh run <name> -- <cmd...>     # run a command IN the env's worktree, cwd-independent
#   agent-env-wp.sh serve <name>               # wp server (+ asset watcher) on the env's port
#   agent-env-wp.sh stop <name>
#   agent-env-wp.sh list
#   agent-env-wp.sh destroy <name> [--force]   # drop DB, remove clone, delete branch if no unique commits
#   agent-env-wp.sh install-hooks              # install git hooks that reconcile theme/plugin deps after a pull (auto-run by create)
#   agent-env-wp.sh sync-deps                  # reconcile deps if a pull changed a lockfile (called by the git hooks)
#
# Reuses the generic engine's primitives (slots, unique_commits guard, pid/health
# machinery, CoW clone). See references/wordpress.md for the model and rationale.

set -euo pipefail

for p in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin "$HOME/Library/Application Support/Herd/bin"; do
  case ":$PATH:" in *":$p:"*) ;; *) PATH="$p:$PATH" ;; esac
done

say()  { echo "agent-env-wp: $*"; }
die()  { echo "agent-env-wp: ERROR: $*" >&2; exit 1; }
warn() { echo "agent-env-wp: WARNING: $*" >&2; }

# ===========================================================================
# >>> PER-PROJECT CONFIG: edit these for your setup.
# ===========================================================================
# Where full-install clones live. Keep it OUT of any Herd/Valet parked path so
# the clones don't get auto-served as <name>.test; we serve them via wp server.
ENV_PARENT="$HOME/WebDev/Sites/.wp-agent-envs"
PORT_BASE=18300                 # slot N -> PORT_BASE + PORT_STRIDE*N
PORT_STRIDE=2                   # >= PORTS_PER_ENV (the floor); densest packing
PORTS_PER_ENV=2                 # wp server + (optional) asset dev/watch server
CANONICAL_BRANCH_PREFIX="worktree-"
WP="wp"                         # WP-CLI binary
WP_SERVER_WORKERS=4             # php -S worker count; MUST be >1 or WordPress
                                # deadlocks (its loopback requests for wp-cron /
                                # Site Health can't be served by a single worker)
# URL handling: "search-replace" = rewrite <host> -> 127.0.0.1:<port> in the env
# DB so the env is fully self-contained (media/content resolve from the env).
# "override" = only set WP_HOME/WP_SITEURL (faster; literal .test URLs in stored
# content still load from the source site via Herd). Override is ALWAYS applied;
# this only toggles the additional search-replace.
URL_MODE="search-replace"
# Lockfiles whose change in a pull triggers project_sync_deps (space-separated,
# repo-root-relative). WP theme/plugin repos commonly carry both.
LOCKFILES="composer.lock package-lock.json"

# Reconcile the theme/plugin repo's dependencies after a pull changed a lockfile.
# Run by the post-merge/post-rewrite git hooks (installed by `install-hooks`) so
# the repo's main checkout can't end up with a composer.json/package.json that
# lists a dependency nobody installed (the trap when an env's PR that added a
# package merges into the repo's main). Runs with cwd = repo root; keep it
# idempotent. Adjust to your repo's actual managers (drop one line if unused).
project_sync_deps() {
  if [[ -f composer.json ]]; then composer install --no-interaction --no-progress; fi
  if [[ -f package.json ]]; then npm install --no-audit --no-fund; fi
  return 0
}
# ===========================================================================

# ---- primitives borrowed from the generic engine --------------------------
clone_dir() {
  local src="$1" dst="$2"
  case "$(uname -s)" in
    Darwin) cp -c -R "$src" "$dst" 2>/dev/null ;;
    *)      cp -R --reflink=auto "$src" "$dst" 2>/dev/null ;;
  esac
}
pid_alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }
port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }
wait_for_url() { # url label timeout
  local url="$1" label="$2" deadline=$((SECONDS + $3))
  until curl -k -s -o /dev/null --max-time 2 "$url"; do
    (( SECONDS < deadline )) || { warn "$label did not respond at $url"; return 1; }
    sleep 1
  done
  say "$label is up: $url"
}
# Commits reachable ONLY from $branch (safe-to-delete check; remote-agnostic).
unique_commits() { git -C "$1" rev-list --count "refs/heads/$2" --not --exclude="$2" --branches --remotes 2>/dev/null || echo "?"; }
canonical_branch() { printf '%s%s\n' "$CANONICAL_BRANCH_PREFIX" "$1"; }
sanitize() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'; }

# ---- WordPress-specific helpers -------------------------------------------
repo_root() { git -C "$1" rev-parse --show-toplevel 2>/dev/null || die "not inside a git repo: $1"; }

wp_root() {  # walk up from $1 until a dir holds wp-config.php
  local d; d=$(cd "$1" && pwd)
  while [[ "$d" != "/" ]]; do
    [[ -f "$d/wp-config.php" ]] && { echo "$d"; return; }
    d=$(dirname "$d")
  done
  die "no wp-config.php found above $1 (run this from inside a WordPress install)"
}

# Per-env state (slot/port/db/install/rel/site + pidfiles) lives under the repo's
# .agent-env/wp/<name>/, alongside the repo, gitignored via .git/info/exclude.
env_dir() { echo "$(repo_root "$PWD")/.agent-env/wp/$1"; }

allocate_slot() { # repo name
  local repo="$1" name="$2" slots="$1/.agent-env/wp-slots" lock used slot tries=0
  mkdir -p "$slots"; lock="$slots/.lock"
  until mkdir "$lock" 2>/dev/null; do (( ++tries < 50 )) || die "slot lock stuck ($lock)"; sleep 0.1; done
  if [[ -f "$slots/$name" ]]; then slot=$(cat "$slots/$name"); else
    used=$(cat "$slots"/* 2>/dev/null || true); slot=1
    while grep -qx "$slot" <<<"$used"; do slot=$((slot+1)); done
    echo "$slot" >"$slots/$name"
  fi
  rmdir "$lock" 2>/dev/null || true; echo "$slot"
}

exclude_artifacts() { # repo
  mkdir -p "$1/.git/info"
  grep -qxF ".agent-env/" "$1/.git/info/exclude" 2>/dev/null || echo ".agent-env/" >>"$1/.git/info/exclude"
}

# ---- dependency-sync git hooks (see agent-env.sh for the rationale) --------
# After a merge/pull/rebase that changes a lockfile, reconcile the theme/plugin
# repo's installed dependencies so a branch that added a package (merged from an
# env's PR) can't leave the repo's main checkout with a manifest listing a
# dependency nobody installed. The hooks just call back into `sync-deps`, which
# runs the per-project project_sync_deps — so a new setup only fills
# project_sync_deps + LOCKFILES in the per-project config above.

write_git_hook() {  # dest-path
  cat >"$1" <<'HOOK'
#!/bin/sh
# Installed by scripts/agent-env-wp.sh (install-hooks). After a merge/pull/rebase
# that changed a lockfile, reconcile this checkout's dependencies so the manifest
# can't list a package nobody installed. The install is the per-project
# project_sync_deps; this delegates so the logic lives in one place.
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -x "$root/scripts/agent-env-wp.sh" ] || exit 0
exec "$root/scripts/agent-env-wp.sh" sync-deps
HOOK
  chmod +x "$1"
}

# Install post-merge + post-rewrite hooks into the theme/plugin repo (repo-global
# via the shared git dir) and point core.hooksPath at them. Idempotent. `--quiet`
# suppresses info output (used by create so it happens without a manual step).
cmd_install_hooks() {
  local quiet="" repo hooks_dir cur
  [[ "${1:-}" == "--quiet" || "${1:-}" == "-q" ]] && quiet=1
  repo=$(repo_root "$PWD")
  hooks_dir="$repo/.githooks"
  mkdir -p "$hooks_dir"
  write_git_hook "$hooks_dir/post-merge"
  write_git_hook "$hooks_dir/post-rewrite"
  cur=$(git -C "$repo" config --local --get core.hooksPath 2>/dev/null || true)
  case "$cur" in
    ""|".git/hooks"|"$repo/.git/hooks")
      git -C "$repo" config core.hooksPath .githooks
      [[ -n "$quiet" ]] || say "git hooks installed (.githooks); core.hooksPath set"
      ;;
    ".githooks") : ;;  # already active
    *)
      warn "core.hooksPath is '$cur'; wrote .githooks/{post-merge,post-rewrite} but left it unchanged — set core.hooksPath=.githooks or chain the hooks from your existing hooks dir" ;;
  esac
  if [[ -z "$quiet" ]] && ! git -C "$repo" ls-files --error-unmatch .githooks/post-merge >/dev/null 2>&1; then
    say "commit .githooks/ so worktrees and collaborators inherit the dependency-sync hook"
  fi
}

# If a watched lockfile ($LOCKFILES) changed in the merge/pull/rebase that just
# finished (ORIG_HEAD..HEAD), run project_sync_deps. Called by the git hooks.
cmd_sync_deps() {
  local root changed lf
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  cd "$root"
  git rev-parse --verify --quiet ORIG_HEAD >/dev/null 2>&1 || return 0
  changed=$(git diff --name-only ORIG_HEAD HEAD 2>/dev/null) || return 0
  for lf in $LOCKFILES; do
    if grep -qxF -- "$lf" <<<"$changed"; then
      say "lockfile changed in pull ($lf); reconciling dependencies via project_sync_deps..."
      project_sync_deps
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
cmd_create() {
  local name="${1:-}" base="${2:-}"
  [[ -n "$name" ]] || die "usage: create <name> [base-ref]"
  [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ && ${#name} -le 40 ]] || die "name must be kebab-case (<=40 chars)"
  local repo wproot site rel branch slot web_port asset_port install db host srcurl
  repo=$(repo_root "$PWD")
  wproot=$(wp_root "$repo")
  site=$(basename "$wproot")
  rel="${repo#"$wproot"/}"
  [[ "$rel" != "$repo" ]] || die "repo $repo is not inside the WP install $wproot"
  [[ -z "$base" ]] && base=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  branch=$(canonical_branch "$name")
  install="$ENV_PARENT/${site}__${name}"
  [[ ! -e "$install" ]] || die "$install already exists (destroy it first)"

  # Reuse a leftover branch only if it carries no unique work.
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    local u; u=$(unique_commits "$repo" "$branch")
    [[ "$u" == "0" ]] && git -C "$repo" branch -D "$branch" >/dev/null \
      || die "branch $branch exists with $u unique commit(s); delete it or pick another name"
  fi

  slot=$(allocate_slot "$repo" "$name")
  (( PORT_STRIDE >= PORTS_PER_ENV )) || die "PORT_STRIDE ($PORT_STRIDE) must be >= PORTS_PER_ENV ($PORTS_PER_ENV); adjacent slots would overlap"
  web_port=$((PORT_BASE + PORT_STRIDE * slot))
  asset_port=$((web_port + 1))
  exclude_artifacts "$repo"

  say "cloning WP install (CoW): $wproot -> $install"
  mkdir -p "$ENV_PARENT"
  clone_dir "$wproot" "$install" || cp -R "$wproot" "$install"

  # Swap the cloned theme/plugin dir for a git worktree on the env branch.
  rm -rf "${install:?}/$rel"
  git -C "$repo" worktree add "$install/$rel" -b "$branch" "$base" --quiet
  say "worktree: $install/$rel  (branch $branch from $base)"

  # Per-env database: copy the site's DB, point the env's wp-config at it.
  db="wp_$(sanitize "${site}_${name}")"
  say "creating per-env database $db"
  # --skip-themes --skip-plugins on DB-level wp calls: WP-CLI bootstraps WordPress
  # (loading the site's plugins/theme) for these, and a plugin that misbehaves in
  # CLI context (common: Beaver Builder, membership/SEO plugins) would fatal and
  # abort us. We only need the DB here, so skip loading them.
  "$WP" db export "$install/.agent-env-db.sql" --path="$wproot" --skip-themes --skip-plugins >/dev/null 2>&1 \
    || die "wp db export failed (is the source site's DB reachable?)"
  mysql -u root -h 127.0.0.1 -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\`" \
    || die "could not create database $db"
  mysql -u root -h 127.0.0.1 "$db" < "$install/.agent-env-db.sql" || die "DB import failed"
  rm -f "$install/.agent-env-db.sql"
  "$WP" config set DB_NAME "$db" --path="$install" >/dev/null

  # URL: override always; optional full search-replace for self-containment.
  "$WP" config set WP_HOME "http://127.0.0.1:$web_port" --type=constant --path="$install" >/dev/null
  "$WP" config set WP_SITEURL "http://127.0.0.1:$web_port" --type=constant --path="$install" >/dev/null
  if [[ "$URL_MODE" == "search-replace" ]]; then
    # `|| true` so a failure here can't abort create under set -e.
    srcurl=$("$WP" option get siteurl --skip-themes --skip-plugins --path="$wproot" 2>/dev/null || true)
    host="${srcurl#*://}"; host="${host%%/*}"
    if [[ -n "$host" ]]; then
      say "search-replace $host -> http://127.0.0.1:$web_port (DB only; media files untouched)"
      # Force scheme to http (wp server is http), covering both http:// and
      # https:// source URLs. wp search-replace is serialization-aware.
      local scheme
      for scheme in https http; do
        "$WP" search-replace "$scheme://$host" "http://127.0.0.1:$web_port" --all-tables-with-prefix \
          --skip-columns=guid --report-changed-only --skip-themes --skip-plugins --path="$install" >/dev/null 2>&1 || true
      done
    else
      warn "could not read source siteurl; skipped search-replace (URL override still applied)"
    fi
  fi

  # Dependencies the theme/plugin needs (PHP vendor for autoload at runtime; npm
  # for its asset watcher). CoW-clone from the source repo when present (instant),
  # else install. We do NOT run a front-end "build": WP themes vary in script
  # names (build/bundle/compile/...) and usually commit built assets, and `serve`
  # runs the project's own watcher for ongoing changes.
  local rp="$install/$rel"
  if [[ -f "$rp/composer.json" && ! -d "$rp/vendor" ]]; then
    say "composer deps for $rel"
    { [[ -d "$repo/vendor" ]] && clone_dir "$repo/vendor" "$rp/vendor"; } \
      || ( cd "$rp" && composer install --no-interaction --no-progress ) \
      || warn "composer install failed for $rel (theme/plugin may not load)"
  fi
  if [[ -f "$rp/package.json" && ! -d "$rp/node_modules" ]]; then
    say "npm deps for $rel"
    { [[ -d "$repo/node_modules" ]] && clone_dir "$repo/node_modules" "$rp/node_modules"; } \
      || ( cd "$rp" && npm ci --no-audit --no-fund ) \
      || warn "npm install failed for $rel (asset watcher may not run)"
  fi

  # Record env state for serve/stop/list/destroy.
  local ed; ed=$(env_dir "$name"); mkdir -p "$ed"
  cat >"$ed/meta.env" <<EOF
AGENT_ENV_NAME=$name
AGENT_ENV_SLOT=$slot
AGENT_ENV_SITE=$site
AGENT_ENV_REL=$rel
AGENT_ENV_INSTALL=$install
AGENT_ENV_BRANCH=$branch
AGENT_ENV_DB=$db
AGENT_ENV_WEB_PORT=$web_port
AGENT_ENV_ASSET_PORT=$asset_port
EOF

  # Ensure the theme/plugin repo has the lockfile-reconcile git hooks (idempotent,
  # quiet). Best-effort: a hook-install hiccup must never fail create.
  cmd_install_hooks --quiet || warn "could not install dependency-sync git hooks"

  say "created '$name'"
  say "  install: $install"
  say "  worktree (edit here): $install/$rel"
  say "  db:      $db"
  say "  serve:   agent-env-wp.sh serve $name   (-> http://127.0.0.1:$web_port)"
}

load_env() { # name -> sources meta.env
  local ed; ed=$(env_dir "$1")
  [[ -f "$ed/meta.env" ]] || die "no env '$1' (looked in $ed)"
  # shellcheck disable=SC1090
  source "$ed/meta.env"
}

# run — execute a command IN the env's code worktree, independent of the shell's
# cwd. The cwd-drift fix (see agent-env.sh): after a restart/resume the agent's
# Bash cwd can reset to the source checkout, so a bare `npm test` / `composer test`
# runs against the wrong tree. This runs in the swapped-in theme/plugin worktree
# ($AGENT_ENV_INSTALL/$AGENT_ENV_REL), where you edit and test. exec passes the
# exit code/signals through; shell features need `run <name> -- bash -lc '...'`.
cmd_run() {
  local name="${1:-}"; [[ -n "$name" ]] || die "usage: agent-env-wp.sh run <name> -- <command...>"
  shift
  [[ "${1:-}" == "--" ]] && shift   # optional separator
  [[ $# -gt 0 ]] || die "run: no command given (agent-env-wp.sh run <name> -- <command...>)"
  load_env "$name"
  cd "$AGENT_ENV_INSTALL/$AGENT_ENV_REL" && exec "$@"
}

cmd_serve() {
  local name="${1:-}"; [[ -n "$name" ]] || die "usage: serve <name>"
  load_env "$name"
  local ed; ed=$(env_dir "$name")
  if pid_alive "$ed/web.pid"; then say "'$name' already serving"; return 0; fi
  port_busy "$AGENT_ENV_WEB_PORT" && die "port $AGENT_ENV_WEB_PORT in use (agent-env-wp.sh stop $name, or a stale process)"
  say "starting '$name' on http://127.0.0.1:$AGENT_ENV_WEB_PORT"
  mkdir -p "$AGENT_ENV_INSTALL/logs"
  # Two deliberate choices here:
  #  - PHP_CLI_SERVER_WORKERS must be >1: WordPress fires loopback HTTP requests
  #    during a page load (wp-cron, Site Health), and php -S with one worker
  #    deadlocks waiting on itself.
  #  - We do NOT auto-start the theme/plugin asset watcher. WP watch scripts
  #    commonly run browser-sync, which binds a fixed port (collides across envs),
  #    tries to open a browser, and holds the parent's stdout open (so `serve`
  #    never returns). Run the watcher manually in the worktree when you're
  #    actively editing CSS/JS (see references/wordpress.md). </dev/null fully
  #    detaches the server from the caller's stdin.
  (
    set -m
    cd "$AGENT_ENV_INSTALL"
    PHP_CLI_SERVER_WORKERS="$WP_SERVER_WORKERS" nohup "$WP" server \
      --host=127.0.0.1 --port="$AGENT_ENV_WEB_PORT" --path="$AGENT_ENV_INSTALL" \
      >>logs/wp-server.log 2>&1 </dev/null &
    echo $! >"$ed/web.pid"
  )
  if ! wait_for_url "http://127.0.0.1:$AGENT_ENV_WEB_PORT/" "wp" 60; then
    tail -5 "$AGENT_ENV_INSTALL/logs/wp-server.log" >&2 2>/dev/null || true
    cmd_stop "$name" >/dev/null; die "'$name' failed to start; see $AGENT_ENV_INSTALL/logs/"
  fi
  say "logs: $AGENT_ENV_INSTALL/logs/"
}

cmd_stop() {
  local name="${1:-}"; [[ -n "$name" ]] || die "usage: stop <name>"
  local ed; ed=$(env_dir "$name"); local pidfile pid
  for pidfile in "$ed"/*.pid; do
    [[ -e "$pidfile" ]] || continue
    pid=$(cat "$pidfile"); kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
  done
  say "stopped $name"
}

cmd_list() {
  local repo wpdir base; repo=$(repo_root "$PWD")
  base="$repo/.agent-env/wp"
  printf '%-20s %-26s %-9s %-22s %s\n' "NAME" "BRANCH" "PORT" "DB" "SERVING"
  [[ -d "$base" ]] || return 0
  local ed name
  for ed in "$base"/*/; do
    [[ -f "$ed/meta.env" ]] || continue
    ( # subshell so sourced vars don't leak
      # shellcheck disable=SC1091
      source "$ed/meta.env"
      serving=no; pid_alive "$ed/web.pid" && serving=yes
      printf '%-20s %-26s %-9s %-22s %s\n' "$AGENT_ENV_NAME" "$AGENT_ENV_BRANCH" "$AGENT_ENV_WEB_PORT" "$AGENT_ENV_DB" "$serving"
    )
  done
}

cmd_destroy() {
  local name="${1:-}" force=0 arg; [[ -n "$name" ]] || die "usage: destroy <name> [--force]"
  shift || true
  for arg in "$@"; do [[ "$arg" == "--force" ]] && force=1 || die "unknown flag: $arg"; done
  load_env "$name"
  local repo ed uniq; repo=$(repo_root "$PWD"); ed=$(env_dir "$name")
  uniq=$(unique_commits "$repo" "$AGENT_ENV_BRANCH")
  cmd_stop "$name" >/dev/null 2>&1 || true
  if (( ! force )); then
    if [[ -n "$(git -C "$AGENT_ENV_INSTALL/$AGENT_ENV_REL" status --porcelain 2>/dev/null)" ]]; then
      die "'$name' worktree has uncommitted changes; commit/push, or rerun with --force"
    fi
    [[ "$uniq" == "0" ]] || die "'$name' has $uniq commit(s) only on $AGENT_ENV_BRANCH; push/merge them, or --force"
  fi
  say "dropping database $AGENT_ENV_DB"
  mysql -u root -h 127.0.0.1 -e "DROP DATABASE IF EXISTS \`$AGENT_ENV_DB\`" 2>/dev/null || warn "could not drop $AGENT_ENV_DB"
  git -C "$repo" worktree remove "$AGENT_ENV_INSTALL/$AGENT_ENV_REL" 2>/dev/null \
    || git -C "$repo" worktree remove --force "$AGENT_ENV_INSTALL/$AGENT_ENV_REL" 2>/dev/null || true
  git -C "$repo" worktree prune
  rm -rf "${AGENT_ENV_INSTALL:?}"
  if [[ "$uniq" == "0" ]]; then
    git -C "$repo" branch -D "$AGENT_ENV_BRANCH" >/dev/null 2>&1 && say "deleted branch $AGENT_ENV_BRANCH (no unique commits)"
  else
    say "branch $AGENT_ENV_BRANCH kept ($uniq unique commit(s) recoverable)"
  fi
  rm -rf "$ed"
  # Free the slot so its ports return to the pool; the next new env reuses the
  # lowest free number (no persistence: recreating this name may get new ports).
  rm -f "$repo/.agent-env/wp-slots/$name"
  say "destroyed '$name' (slot ${AGENT_ENV_SLOT:-?} freed)"
}

cmd="${1:-}"; [[ -n "$cmd" ]] && shift || { sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
case "$cmd" in
  create)  cmd_create "$@" ;;
  run)     cmd_run "$@" ;;
  serve)   cmd_serve "$@" ;;
  stop)    cmd_stop "$@" ;;
  list)    cmd_list "$@" ;;
  destroy) cmd_destroy "$@" ;;
  install-hooks) cmd_install_hooks "$@" ;;
  sync-deps) cmd_sync_deps "$@" ;;
  *) sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
