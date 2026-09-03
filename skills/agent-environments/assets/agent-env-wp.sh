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
# Run this from the theme/plugin repo's MAIN checkout. It finds the enclosing WP
# install automatically. Sibling repos listed in SIBLING_REPOS get a worktree of
# their own in every env, on the same branch name, and are reclaimed by destroy.
#
# Usage:
#   agent-env-wp.sh create <name> [base-ref]   # clone install + worktree(s) + DB + config
#   agent-env-wp.sh run <name> -- <cmd...>     # run a command IN the env's worktree, cwd-independent
#   agent-env-wp.sh serve <name>               # wp server (+ asset watcher) on the env's port
#   agent-env-wp.sh stop <name>
#   agent-env-wp.sh list
#   agent-env-wp.sh destroy <name> [--force]   # drop DB, remove clone + worktrees, delete branches if no unique commits; refuses to run from inside the env
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
WEB_HOST="localhost"            # host the env is served and addressed on. Prefer a
                                # NAME over a bare IP: third-party services that
                                # restrict by origin/referrer (Font Awesome kits,
                                # Google Maps / reCAPTCHA keys, Mapbox) allowlist
                                # DOMAINS, usually permit localhost by default, and
                                # cannot allowlist an IP at all. On 127.0.0.1 those
                                # 403 and their widgets silently vanish, so visual
                                # QA in an env looks like the branch broke the site.
                                # WEB address only: the mysql -h below stays
                                # 127.0.0.1 (that is the DB connection, where a
                                # name would switch TCP for a unix socket).
# URL handling: "search-replace" = rewrite <host> -> $WEB_HOST:<port> in the env
# DB so the env is fully self-contained (media/content resolve from the env).
# "override" = only set WP_HOME/WP_SITEURL (faster; literal .test URLs in stored
# content still load from the source site via Herd). Override is ALWAYS applied;
# this only toggles the additional search-replace.
URL_MODE="search-replace"
# Lockfiles whose change in a pull triggers project_sync_deps (space-separated,
# repo-root-relative). WP theme/plugin repos commonly carry both.
LOCKFILES="composer.lock package-lock.json"
# Other custom repos in this install that every env should branch alongside this
# one (space-separated, install-relative, e.g. "wp-content/plugins/my-plugin").
# The canonical case is a custom theme plus a custom plugin: each repo's copy of
# this script lists the OTHER. create gives each sibling a worktree on the same
# `worktree-<name>` branch, from that checkout's current branch; destroy reclaims
# it under the same dirty/unpushed guard. Everything not listed stays a CoW
# snapshot, which is right for third-party code. The list is explicit on purpose:
# vendored plugins carry .git directories too, so detection would branch those.
SIBLING_REPOS=""

# Build step for a fresh worktree, run with cwd = that worktree once its
# dependencies are in place: once for this repo, once per sibling. Compiled
# assets are usually gitignored, so a fresh worktree has none and the site
# renders unstyled. Dispatch on the install-relative path when siblings differ.
project_after_worktree() { # <install-relative path>
  return 0
}

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
# True only if the pidfile names a LIVE process that is still this env's server.
# A bare kill -0 is not enough: once the server exits, the OS can recycle its PID
# onto an unrelated process, which would make `serve` report success without
# serving and `stop`/`destroy` signal a stranger. The command line carries
# --port=<port>, so that is the identity check. Port omitted -> liveness only.
server_alive() { # pidfile [port]
  local pid; pid=$(cat "$1" 2>/dev/null || true)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || return 1
  [[ -z "${2:-}" ]] || ps -o command= -p "$pid" 2>/dev/null | grep -q -- "--port=$2"
}
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
# A branch that does not exist has nothing to lose, so it reports 0 — that is what
# lets `destroy` reclaim an env whose `create` died before `git worktree add`.
unique_commits() {
  git -C "$1" show-ref --verify --quiet "refs/heads/$2" || { echo 0; return; }
  git -C "$1" rev-list --count "refs/heads/$2" --not --exclude="$2" --branches --remotes 2>/dev/null || echo "?"
}
canonical_branch() { printf '%s%s\n' "$CANONICAL_BRANCH_PREFIX" "$1"; }
sanitize() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'; }

# ---- WordPress-specific helpers -------------------------------------------
# The MAIN checkout, resolved from anywhere -- including from inside an env's own
# worktree. Do not "simplify" this back to --show-toplevel: that returns the current
# worktree, so every lookup below then misses (env metadata lives under the main
# checkout), `run`/`serve`/`destroy` report the env as unknown, and `create` resolves
# wp_root to the ENV's WordPress install and clones that instead of the real site.
# --git-common-dir is the shared .git every worktree points back to; the generic
# engine's main_root() in agent-env.sh does the same thing.
repo_root() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "not inside a git repo: $1"
  dirname "$common"
}

# The theme/plugin repo's branch and dirty state. This checkout plays the "main
# checkout" role here, and in the human+agent mode a person is working in it on
# their own branch, so nothing may assume it sits on the default branch. Read it
# and print it instead.
repo_state() {  # <repo-root> -> "<branch> (clean|dirty)"
  local b d
  b=$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || b="detached at $(git -C "$1" rev-parse --short HEAD 2>/dev/null || echo '?')"
  if [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]; then d=dirty; else d=clean; fi
  printf '%s (%s)\n' "$b" "$d"
}

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

# Slots live under ENV_PARENT, not under the repo, because ports are machine-wide:
# every repo whose script points at the same ENV_PARENT draws from one pool, so a
# theme env and a plugin env of the same site (or of two sites) never share a
# port without anyone coordinating PORT_BASE bands by hand. A slot is taken when
# the registry says so OR an existing env under ENV_PARENT already declares its
# port in wp-config.php. The second source is the ground truth: it covers envs
# made by earlier versions of this script (which kept slots under the repo) and
# a registry entry that went missing, both of which handed out a live port once.
allocate_slot() { # site name
  local key="${1}__${2}" slots="$ENV_PARENT/.wp-slots" lock used slot tries=0 cfg port
  mkdir -p "$slots"; lock="$slots/.lock"
  until mkdir "$lock" 2>/dev/null; do (( ++tries < 50 )) || die "slot lock stuck ($lock)"; sleep 0.1; done
  if [[ -f "$slots/$key" ]]; then slot=$(cat "$slots/$key"); else
    used=$(cat "$slots"/* 2>/dev/null || true)
    for cfg in "$ENV_PARENT"/*/wp-config.php; do
      port=$(sed -n "s/.*'WP_HOME', *'http:\/\/[^:']*:\([0-9]*\)'.*/\1/p" "$cfg" 2>/dev/null | head -1)
      [[ -n "$port" ]] && used+=$'\n'$(( (port - PORT_BASE) / PORT_STRIDE ))
    done
    slot=1
    while grep -qx "$slot" <<<"$used"; do slot=$((slot+1)); done
    echo "$slot" >"$slots/$key"
  fi
  rmdir "$lock" 2>/dev/null || true; echo "$slot"
}
free_slot() { # repo site name
  rm -f "$ENV_PARENT/.wp-slots/${2}__${3}" "$1/.agent-env/wp-slots/$3"
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
  local quiet="" repo hooks_dir cur eff existing
  [[ "${1:-}" == "--quiet" || "${1:-}" == "-q" ]] && quiet=1
  repo=$(repo_root "$PWD")
  hooks_dir="$repo/.githooks"
  mkdir -p "$hooks_dir"
  write_git_hook "$hooks_dir/post-merge"
  write_git_hook "$hooks_dir/post-rewrite"
  cur=$(git -C "$repo" config --local --get core.hooksPath 2>/dev/null || true)
  # An unset LOCAL hooksPath does not mean none is in effect: a global or system
  # core.hooksPath still applies, and writing a local one would override it.
  eff=$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)
  if [[ -z "$cur" && -n "$eff" && "$eff" != ".githooks" ]]; then
    warn "core.hooksPath is '$eff' (configured outside this repo); wrote .githooks/{post-merge,post-rewrite} but left it unchanged — set it locally to .githooks, or chain these hooks from '$eff'"
    return 0
  fi
  # An unset core.hooksPath does NOT mean "no hooks": git falls back to
  # .git/hooks, so repos using pre-commit/husky-style hooks there are live.
  # Pointing core.hooksPath at .githooks would silently disable every one of
  # them, so treat real hooks in .git/hooks the same as a foreign hooksPath.
  # Symlinks count: hook managers commonly link them in, and git runs anything
  # executable there, so -type f alone would miss them and switch anyway.
  existing=$(find "$repo/.git/hooks" -maxdepth 1 ! -name '*.sample' \( -type f -o -type l \) -perm -u+x 2>/dev/null | head -3 || true)
  case "$cur" in
    ""|".git/hooks"|"$repo/.git/hooks")
      if [[ -n "$existing" ]]; then
        warn "left core.hooksPath unset: $repo/.git/hooks already holds active hooks ($(echo "$existing" | xargs -n1 basename | tr '\n' ' ')) that switching to .githooks would disable — move them into .githooks/ (or chain them from there), then rerun install-hooks"
      else
        git -C "$repo" config core.hooksPath .githooks
        [[ -n "$quiet" ]] || say "git hooks installed (.githooks); core.hooksPath set"
      fi
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

# Per-name lifecycle mutex. create and destroy both mutate the same install,
# slot, claim, branch and database, so they must exclude EACH OTHER, not merely
# notice each other: observing the lock still lets destroy delete paths a
# concurrently-starting create is filling in. Both acquire it for their whole
# run and release here from the EXIT trap, on every path (success, die,
# interrupt). Guarded because the trap can fire before any lock was taken.
AGENT_ENV_LOCK=""
# Keyed by site and name under ENV_PARENT, like the slot pool: the install path,
# database and slot are per site, so a theme `create foo` and a plugin `create
# foo` must exclude each other, which a per-repo lock cannot do.
env_lock_path() { echo "$ENV_PARENT/.locks/$(sanitize "${1}__${2}")"; }
take_env_lock() { # site name verb
  AGENT_ENV_LOCK=$(env_lock_path "$1" "$2")
  mkdir -p "$ENV_PARENT/.locks"
  mkdir "$AGENT_ENV_LOCK" 2>/dev/null \
    || { AGENT_ENV_LOCK=""; die "another lifecycle operation for '$2' is already running, so $3 would race it (if that process died, remove $(env_lock_path "$1" "$2"))"; }
  trap release_env_lock EXIT
}
release_env_lock() { [[ -n "${AGENT_ENV_LOCK:-}" ]] && rm -rf "$AGENT_ENV_LOCK"; return 0; }

# Dependencies a worktree needs (PHP vendor for autoload at runtime; npm for its
# asset watcher): CoW-clone from its main checkout when present (instant), else
# install; then the per-project build step. No generic front-end "build": WP
# repos vary in script names and usually commit built assets, which is what
# project_after_worktree is for.
provision_worktree_deps() { # main-checkout worktree-path rel
  local main="$1" rp="$2" rel="$3"
  if [[ -f "$rp/composer.json" ]]; then
    say "composer deps for $rel"
    { [[ -d "$main/vendor" && ! -d "$rp/vendor" ]] && clone_dir "$main/vendor" "$rp/vendor"; } || true
    # Always reconcile to the lockfile (no-op when complete): a bare "dir exists"
    # check is fooled by a failed/partial clone or a repo that tracks a partial
    # vendor subset (some starters committed the phpcs toolchain pre-gitignore).
    ( cd "$rp" && composer install --no-interaction --no-progress ) \
      || warn "composer install failed for $rel (theme/plugin may not load)"
  fi
  if [[ -f "$rp/package.json" ]]; then
    if [[ ! -d "$rp/node_modules" ]]; then
      say "npm deps for $rel"
      { [[ -d "$main/node_modules" ]] && clone_dir "$main/node_modules" "$rp/node_modules"; } \
        || ( cd "$rp" && npm ci --no-audit --no-fund ) \
        || warn "npm install failed for $rel (asset watcher may not run)"
    fi
    # A cloned node_modules mirrors the SOURCE checkout, which may sit on a
    # different lockfile than the env branch — the env would then run on packages
    # that do not match its own code. Reconcile only when the lockfiles actually
    # differ, so the common case keeps the instant CoW path (this is the npm
    # half of the reconcile the composer branch above always does).
    if [[ -f "$rp/package-lock.json" ]] && ! cmp -s "$main/package-lock.json" "$rp/package-lock.json"; then
      say "lockfile differs from the source checkout; reconciling npm deps for $rel"
      ( cd "$rp" && npm ci --no-audit --no-fund ) \
        || warn "npm ci failed for $rel (dependencies may not match the env branch)"
    fi
  fi
  ( cd "$rp" && project_after_worktree "$rel" ) \
    || warn "project_after_worktree failed for $rel (compiled assets may be missing)"
}

# A sibling repo's CoW snapshot becomes a worktree of its main checkout on the
# env branch, from whatever that checkout has checked out (announced, like the
# target repo's default base).
add_sibling_worktree() { # main-checkout worktree-path branch rel
  local main="$1" wt="$2" branch="$3" rel="$4" sbase
  sbase=$(git -C "$main" rev-parse --abbrev-ref HEAD)
  say "sibling $rel: worktree on $branch from its checkout's current branch '$sbase'"
  [[ -z "$(git -C "$main" status --porcelain 2>/dev/null)" ]] \
    || warn "that checkout has uncommitted changes; the env branches from its last COMMIT"
  rm -rf "${wt:?}"
  git -C "$main" worktree add "$wt" -b "$branch" "$sbase" --quiet
  provision_worktree_deps "$main" "$wt" "$rel"
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
  if [[ -z "$base" ]]; then
    # WP repos usually sit on a long-lived feature branch, so the current branch
    # is the right default here (unlike the generic engine, which defaults to
    # `main`). Announce it: if a person is also working in this checkout, the
    # default inherits THEIR branch, which is rarely what was intended.
    base=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
    say "no base-ref given; branching from the checkout's current branch '$base'"
    [[ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]] \
      || warn "that checkout has uncommitted changes; an env branches from the last COMMIT, so they will not be in it"
  fi
  branch=$(canonical_branch "$name")
  # The name pattern above still admits refs git rejects ('a..b', 'a.', 'a.lock').
  # Catch that here rather than at `git worktree add`, which runs after the claim,
  # slot, metadata and a full clone — a failure there costs a manual destroy.
  git check-ref-format "refs/heads/$branch" 2>/dev/null \
    || die "name '$name' makes an invalid git branch ($branch); avoid '..', a trailing '.', and the '.lock' suffix"
  # Same rationale for the BASE ref: a bad one otherwise surfaces at `git
  # worktree add`, which runs after the claim, slot, metadata and a 1.8 GB clone.
  git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
    || die "base ref '$base' not found in $repo (usage: create <name> [base-ref])"
  install="$ENV_PARENT/${site}__${name}"

  # Serialize creates of the SAME name. The install-path check below is a
  # read-then-write test: two concurrent `create foo` calls both pass it and then
  # share one slot, install path, branch and database, clobbering each other.
  # mkdir is the atomic gate; the trap releases it on success, failure or die.
  take_env_lock "$site" "$name" "creating it"

  [[ ! -e "$install" ]] || die "$install already exists (destroy it first)"

  # A registration left by a destroy that ran through an env's older in-tree
  # script copy would make git refuse to delete the leftover branch below.
  git -C "$repo" worktree prune 2>/dev/null || true
  # Reuse a leftover branch only if it carries no unique work.
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    local u; u=$(unique_commits "$repo" "$branch")
    [[ "$u" == "0" ]] && git -C "$repo" branch -D "$branch" >/dev/null \
      || die "branch $branch exists with $u unique commit(s); delete it or pick another name"
  fi
  # Siblings get the same branch name in their own repo, so the same reuse rule
  # applies there, checked now so a refusal costs nothing.
  local siblings="" s srepo su
  for s in $SIBLING_REPOS; do
    srepo="$wproot/$s"
    [[ "$s" != "$rel" ]] || die "SIBLING_REPOS lists this repo itself ($rel)"
    [[ -e "$srepo/.git" ]] || die "SIBLING_REPOS entry '$s' is not a git checkout at $srepo"
    git -C "$srepo" worktree prune 2>/dev/null || true
    if git -C "$srepo" show-ref --verify --quiet "refs/heads/$branch"; then
      su=$(unique_commits "$srepo" "$branch")
      [[ "$su" == "0" ]] && git -C "$srepo" branch -D "$branch" >/dev/null \
        || die "branch $branch exists in sibling $s with $su unique commit(s); delete it or pick another name"
    fi
    siblings="${siblings:+$siblings }$s"
  done

  db="wp_$(sanitize "${site}_${name}")"
  # sanitize() maps every non-alphanumeric to '_', so two names that differ only
  # in separator ('a-b' vs 'a_b') resolve to ONE database — and the DROP later
  # would silently destroy the other env's data while it is still running.
  #
  # The claim is a mkdir, which is atomic across processes: a read-then-write
  # check would let two concurrent creates both pass before either recorded
  # anything, and running creates in parallel is the whole point of this tool.
  # Claimed before allocate_slot so a refusal leaves no slot behind.
  #
  # An existing claim is ALWAYS occupied, even when its owner file is unreadable:
  # the owner is written just after the winning mkdir, so a rival that treated
  # "no owner yet" as stale would sail straight through the window the claim
  # exists to close. Only the claim's own env may proceed, which is what lets a
  # failed create be retried under the same name.
  local claim="$ENV_PARENT/.db-claims/$db" owner="" claim_fresh=1
  mkdir -p "$ENV_PARENT/.db-claims"
  if ! mkdir "$claim" 2>/dev/null; then
    claim_fresh=0
    owner=$(cat "$claim/owner" 2>/dev/null || true)
    [[ "$owner" == "$name" ]] \
      || die "database $db is already claimed by env '${owner:-<unknown>}' (names differing only in separator collide); pick another name, or if that env is gone remove $claim"
  fi
  printf '%s\n' "$name" >"$claim/owner"

  # A brand-new claim must not land on an existing database: that DB belongs to
  # something else (made by hand, or an env whose local state was wiped), and the
  # DROP later would take its data with it. A pre-existing claim we own is
  # different — that is a retry of our own create, so dropping is correct.
  # Checked here, before the slot and the clone, so a refusal costs nothing.
  if (( claim_fresh )) && mysql -u root -h 127.0.0.1 -N -B -e "SHOW DATABASES LIKE '$db'" 2>/dev/null | grep -qx "$db"; then
    rm -rf "$claim"
    die "database $db already exists but no env claims it; drop it yourself or pick another name"
  fi

  slot=$(allocate_slot "$site" "$name")
  (( PORT_STRIDE >= PORTS_PER_ENV )) || die "PORT_STRIDE ($PORT_STRIDE) must be >= PORTS_PER_ENV ($PORTS_PER_ENV); adjacent slots would overlap"
  web_port=$((PORT_BASE + PORT_STRIDE * slot))
  asset_port=$((web_port + 1))
  exclude_artifacts "$repo"

  # Record env state BEFORE the first mutation. Everything here is already known,
  # and writing it up front is what makes a partial env recoverable: if create
  # dies after the clone or the DB import, `destroy` can still load and reclaim
  # it. Written late, that failure leaves a slot, an install dir, a branch and
  # possibly a database that `destroy` cannot see and `create` refuses to reuse.
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
AGENT_ENV_SIBLINGS="$siblings"
EOF

  say "cloning WP install (CoW): $wproot -> $install"
  mkdir -p "$ENV_PARENT"
  clone_dir "$wproot" "$install" || cp -R "$wproot" "$install"

  # Swap the cloned theme/plugin dir for a git worktree on the env branch.
  rm -rf "${install:?}/$rel"
  git -C "$repo" worktree add "$install/$rel" -b "$branch" "$base" --quiet
  say "worktree: $install/$rel  (branch $branch from $base)"

  # Per-env database: copy the site's DB, point the env's wp-config at it.
  # ($db was resolved and collision-checked before the clone.)
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
  "$WP" config set WP_HOME "http://$WEB_HOST:$web_port" --type=constant --path="$install" >/dev/null
  "$WP" config set WP_SITEURL "http://$WEB_HOST:$web_port" --type=constant --path="$install" >/dev/null
  if [[ "$URL_MODE" == "search-replace" ]]; then
    # `|| true` so a failure here can't abort create under set -e.
    srcurl=$("$WP" option get siteurl --skip-themes --skip-plugins --path="$wproot" 2>/dev/null || true)
    host="${srcurl#*://}"; host="${host%%/*}"
    if [[ -n "$host" ]]; then
      say "search-replace $host -> http://$WEB_HOST:$web_port (DB only; media files untouched)"
      # Force scheme to http (wp server is http), covering both http:// and
      # https:// source URLs. wp search-replace is serialization-aware.
      local scheme
      for scheme in https http; do
        "$WP" search-replace "$scheme://$host" "http://$WEB_HOST:$web_port" --all-tables-with-prefix \
          --skip-columns=guid --report-changed-only --skip-themes --skip-plugins --path="$install" >/dev/null 2>&1 || true
      done
    else
      warn "could not read source siteurl; skipped search-replace (URL override still applied)"
    fi
  fi

  provision_worktree_deps "$repo" "$install/$rel" "$rel"
  for s in $siblings; do
    add_sibling_worktree "$wproot/$s" "$install/$s" "$branch" "$s"
  done

  # Ensure the theme/plugin repo has the lockfile-reconcile git hooks (idempotent,
  # quiet). Best-effort: a hook-install hiccup must never fail create.
  cmd_install_hooks --quiet || warn "could not install dependency-sync git hooks"

  # Completion marker, written last. meta.env is deliberately written BEFORE the
  # clone so `destroy` can reclaim a half-built env — but that also makes a
  # half-built env loadable, and its wp-config still names the SOURCE database
  # until `wp config set DB_NAME` runs. Serving one would point WordPress (cron,
  # plugins, writes) at the real site's data. `serve` and `run` refuse without
  # this line; `destroy` and `list` deliberately do not require it.
  echo "AGENT_ENV_READY=1" >>"$ed/meta.env"

  say "created '$name'"
  say "  install: $install"
  say "  worktree (edit here): $install/$rel"
  for s in $siblings; do say "  sibling worktree:     $install/$s"; done
  say "  db:      $db"
  say "  serve:   agent-env-wp.sh serve $name   (-> http://$WEB_HOST:$web_port)"
}

load_env() { # name -> sources meta.env
  local ed; ed=$(env_dir "$1")
  [[ -f "$ed/meta.env" ]] || die "no env '$1' (looked in $ed)"
  # shellcheck disable=SC1090
  source "$ed/meta.env"
}

# load_env for the commands that RUN the env. A half-built env (create died
# partway) still has meta.env by design, but its wp-config may still point at
# the source database — using it would break the isolation the env exists for.
load_ready_env() { # name
  load_env "$1"
  [[ "${AGENT_ENV_READY:-}" == "1" ]] \
    || die "env '$1' is incomplete (create did not finish; it may still point at the source database) — 'destroy $1' and create it again"
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
  load_ready_env "$name"
  cd "$AGENT_ENV_INSTALL/$AGENT_ENV_REL" && exec "$@"
}

cmd_serve() {
  local name="${1:-}"; [[ -n "$name" ]] || die "usage: serve <name>"
  load_ready_env "$name"
  # Startup is check-then-spawn-then-write-pid: two concurrent serves would both
  # pass the checks, both spawn, and the loser's dead PID could land in web.pid
  # last, orphaning the live server beyond stop's reach. Serving also must not
  # begin while destroy is tearing the env down. Same per-name mutex, held for
  # the startup sequence only — the server itself outlives this command.
  take_env_lock "$AGENT_ENV_SITE" "$name" "serving it"
  local ed; ed=$(env_dir "$name")
  if server_alive "$ed/web.pid" "$AGENT_ENV_WEB_PORT"; then say "'$name' already serving"; return 0; fi
  port_busy "$AGENT_ENV_WEB_PORT" && die "port $AGENT_ENV_WEB_PORT in use (agent-env-wp.sh stop $name, or a stale process)"
  say "starting '$name' on http://$WEB_HOST:$AGENT_ENV_WEB_PORT"
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
      --host="$WEB_HOST" --port="$AGENT_ENV_WEB_PORT" --path="$AGENT_ENV_INSTALL" \
      >>logs/wp-server.log 2>&1 </dev/null &
    echo $! >"$ed/web.pid"
  )
  if ! wait_for_url "http://$WEB_HOST:$AGENT_ENV_WEB_PORT/" "wp" 60; then
    tail -5 "$AGENT_ENV_INSTALL/logs/wp-server.log" >&2 2>/dev/null || true
    cmd_stop "$name" >/dev/null; die "'$name' failed to start; see $AGENT_ENV_INSTALL/logs/"
  fi
  say "logs: $AGENT_ENV_INSTALL/logs/"
}

cmd_stop() {
  local name="${1:-}"; [[ -n "$name" ]] || die "usage: stop <name>"
  local ed port; ed=$(env_dir "$name"); local pidfile pid
  # Read the port directly rather than via load_env, which dies on a missing
  # meta.env — stop must stay usable from destroy's cleanup path.
  port=$(sed -n 's/^AGENT_ENV_WEB_PORT=//p' "$ed/meta.env" 2>/dev/null || true)
  for pidfile in "$ed"/*.pid; do
    [[ -e "$pidfile" ]] || continue
    pid=$(cat "$pidfile" 2>/dev/null || true)
    # If the server already exited, the OS may have recycled its PID onto an
    # unrelated process — and the group kill fails over to a direct kill, which
    # would take that process down. Only signal a PID whose command line still
    # carries this env's port; otherwise just drop the stale pidfile.
    if server_alive "$pidfile" "$port"; then
      kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  done
  say "stopped $name"
}

cmd_list() {
  local repo wpdir base; repo=$(repo_root "$PWD")
  base="$repo/.agent-env/wp"
  printf 'repo checkout: %s  [%s]\n\n' "$repo" "$(repo_state "$repo")"
  printf '%-20s %-26s %-9s %-30s %s\n' "NAME" "BRANCH" "PORT" "DB" "SERVING"
  [[ -d "$base" ]] || return 0
  local ed name
  for ed in "$base"/*/; do
    [[ -f "$ed/meta.env" ]] || continue
    ( # subshell so sourced vars don't leak
      # shellcheck disable=SC1091
      source "$ed/meta.env"
      serving=no; server_alive "$ed/web.pid" "$AGENT_ENV_WEB_PORT" && serving=yes
      printf '%-20s %-26s %-9s %-30s %s\n' "$AGENT_ENV_NAME" "$AGENT_ENV_BRANCH" "$AGENT_ENV_WEB_PORT" "$AGENT_ENV_DB" "$serving"
    )
  done
}

cmd_destroy() {
  local name="${1:-}" force=0 arg; [[ -n "$name" ]] || die "usage: destroy <name> [--force]"
  shift || true
  for arg in "$@"; do [[ "$arg" == "--force" ]] && force=1 || die "unknown flag: $arg"; done
  load_env "$name"
  local repo ed uniq wproot; repo=$(repo_root "$PWD"); ed=$(env_dir "$name"); wproot=$(wp_root "$repo")
  # Never from inside the env: rm -rf would take the shell's working directory
  # with it. Checked against the path rather than the session's launch
  # directory: a hook that keyed on the launch directory lost track after a
  # desktop-app restart, which relaunches the session where it is.
  local here inst; here=$(pwd -P)
  inst=$(cd "$AGENT_ENV_INSTALL" 2>/dev/null && pwd -P || printf '%s' "$AGENT_ENV_INSTALL")
  [[ "$here" != "$inst" && "$here" != "$inst"/* ]] \
    || die "destroy must run from outside the env. Move the session's working directory to $repo first (desktop app: change_directory; after EnterWorktree: ExitWorktree with action keep), then rerun: $repo/scripts/$(basename "$0") destroy $name"
  # meta.env exists from the start of create, so destroy can reach a live
  # creation. Take the lifecycle mutex for the whole teardown.
  take_env_lock "$AGENT_ENV_SITE" "$name" "destroying it"
  uniq=$(unique_commits "$repo" "$AGENT_ENV_BRANCH")
  cmd_stop "$name" >/dev/null 2>&1 || true
  local s srepo swt suniq
  if (( ! force )); then
    # Only inspect a worktree that is actually there (.git is a FILE): a create
    # that died before `git worktree add` leaves either nothing or the CoW
    # snapshot of the main checkout (.git a directory), which holds no work of
    # its own and is what create would have rm -rf'd anyway. But if the worktree
    # DOES exist and git cannot read it, treat that as unsafe rather than clean —
    # suppressing the error would let rm -rf delete modified files.
    if [[ -f "$AGENT_ENV_INSTALL/$AGENT_ENV_REL/.git" ]]; then
      local dirty strc=0
      dirty=$(git -C "$AGENT_ENV_INSTALL/$AGENT_ENV_REL" status --porcelain 2>/dev/null) || strc=$?
      (( strc == 0 )) || die "'$name': cannot read the worktree's git status at $AGENT_ENV_INSTALL/$AGENT_ENV_REL (missing or corrupt metadata); inspect it, or rerun with --force to delete it anyway"
      [[ -z "$dirty" ]] || die "'$name' worktree has uncommitted changes; commit/push, or rerun with --force"
    fi
    [[ "$uniq" == "0" ]] || die "'$name' has $uniq commit(s) only on $AGENT_ENV_BRANCH; push/merge them, or --force"
    # The same guard for every sibling worktree, all before anything is touched.
    for s in ${AGENT_ENV_SIBLINGS:-}; do
      srepo="$wproot/$s"; swt="$AGENT_ENV_INSTALL/$s"
      [[ -e "$srepo/.git" ]] || continue
      if [[ -f "$swt/.git" ]]; then
        local sdirty sstrc=0
        sdirty=$(git -C "$swt" status --porcelain 2>/dev/null) || sstrc=$?
        (( sstrc == 0 )) || die "'$name': cannot read the sibling worktree's git status at $swt (missing or corrupt metadata); inspect it, or rerun with --force to delete it anyway"
        [[ -z "$sdirty" ]] || die "'$name' sibling worktree $s has uncommitted changes; commit/push, or rerun with --force"
      fi
      suniq=$(unique_commits "$srepo" "$AGENT_ENV_BRANCH")
      [[ "$suniq" == "0" ]] || die "'$name' has $suniq commit(s) only on $AGENT_ENV_BRANCH in sibling $s; push/merge them, or --force"
    done
  fi
  say "dropping database $AGENT_ENV_DB"
  mysql -u root -h 127.0.0.1 -e "DROP DATABASE IF EXISTS \`$AGENT_ENV_DB\`" 2>/dev/null || warn "could not drop $AGENT_ENV_DB"
  git -C "$repo" worktree remove "$AGENT_ENV_INSTALL/$AGENT_ENV_REL" 2>/dev/null \
    || git -C "$repo" worktree remove --force "$AGENT_ENV_INSTALL/$AGENT_ENV_REL" 2>/dev/null || true
  # A sibling checkout that moved away since create is skipped with a note
  # rather than aborting the teardown half-way under set -e.
  for s in ${AGENT_ENV_SIBLINGS:-}; do
    srepo="$wproot/$s"
    [[ -e "$srepo/.git" ]] || { warn "sibling $s checkout missing at $srepo; skipping its worktree and branch cleanup"; continue; }
    git -C "$srepo" worktree remove "$AGENT_ENV_INSTALL/$s" 2>/dev/null \
      || git -C "$srepo" worktree remove --force "$AGENT_ENV_INSTALL/$s" 2>/dev/null || true
  done
  rm -rf "${AGENT_ENV_INSTALL:?}"
  # Prune after the directory is gone, so a registration `worktree remove`
  # could not clear is dropped too, and the branch below can be deleted.
  git -C "$repo" worktree prune 2>/dev/null || true
  if [[ "$uniq" == "0" ]]; then
    git -C "$repo" branch -D "$AGENT_ENV_BRANCH" >/dev/null 2>&1 && say "deleted branch $AGENT_ENV_BRANCH (no unique commits)"
  else
    say "branch $AGENT_ENV_BRANCH kept ($uniq unique commit(s) recoverable)"
  fi
  for s in ${AGENT_ENV_SIBLINGS:-}; do
    srepo="$wproot/$s"
    [[ -e "$srepo/.git" ]] || continue
    git -C "$srepo" worktree prune 2>/dev/null || true
    if [[ "$(unique_commits "$srepo" "$AGENT_ENV_BRANCH")" == "0" ]]; then
      git -C "$srepo" branch -D "$AGENT_ENV_BRANCH" >/dev/null 2>&1 && say "sibling $s: deleted branch $AGENT_ENV_BRANCH (no unique commits)"
    else
      say "sibling $s: kept branch $AGENT_ENV_BRANCH (unique commits recoverable)"
    fi
  done
  rm -rf "$ed"
  # Free the slot so its ports return to the pool; the next new env reuses the
  # lowest free number (no persistence: recreating this name may get new ports).
  free_slot "$repo" "$AGENT_ENV_SITE" "$name"
  # Release the database-name claim so the name can be created again (the
  # second path is where versions before the shared pool kept it).
  rm -rf "${AGENT_ENV_DB:+$ENV_PARENT/.db-claims/$AGENT_ENV_DB}" "${AGENT_ENV_DB:+$repo/.agent-env/db-claims/$AGENT_ENV_DB}"
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
