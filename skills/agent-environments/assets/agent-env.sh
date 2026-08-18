#!/usr/bin/env bash
#
# agent-env.sh: isolated parallel environments for coding agents.
#
# Each environment is a git worktree under .claude/worktrees/<name> (the
# runtime's native location, so Claude sessions can EnterWorktree into it),
# provisioned with everything needed to run this project in isolation:
# copy-on-write-cloned dependencies (near-zero disk until divergence), a config
# file with a unique port set, and a logs dir. Several environments run side by
# side without colliding on ports, dependencies, or branches.
#
# Usage:
#   agent-env.sh create <name> [base-ref] [--resume]  # worktree + branch + provision
#                                          # --resume reattaches an existing branch
#   agent-env.sh provision [path]          # provision an existing worktree (default: cwd)
#   agent-env.sh run <name|path> -- <cmd...>  # run a command IN the env, cwd-independent
#   agent-env.sh serve <name|path> [--main-ports]
#   agent-env.sh stop <name|path>
#   agent-env.sh list
#   agent-env.sh destroy <name|path> [--force]  # deletes the branch only if merged
#   agent-env.sh install-hooks             # install git hooks that reconcile deps after a pull (setup; auto-run by provision)
#   agent-env.sh sync-deps                 # reconcile deps if a pull changed a lockfile (called by the git hooks)
#
# Inside an env, ALWAYS use `serve`, never the main dev command, which is
# pinned to the main checkout's ports and would collide.
#
# ADAPTING THIS SCRIPT TO A NEW PROJECT: edit only the PER-PROJECT SECTION
# below (the CONFIG block + the project_* functions). The ENGINE beneath it is
# stack-agnostic and can be copied verbatim. See the skill's references/stacks.md
# for per-stack guidance (which dep dirs to clone, ports, services, etc.).

set -euo pipefail

# The Claude Code sandbox PATH may lack Homebrew; node/npm/php live there.
for p in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin; do
  case ":$PATH:" in *":$p:"*) ;; *) PATH="$p:$PATH" ;; esac
done

say()  { echo "agent-env: $*"; }
die()  { echo "agent-env: ERROR: $*" >&2; exit 1; }
warn() { echo "agent-env: WARNING: $*" >&2; }

# Copy-on-write clone a directory; returns non-zero if CoW is unavailable so
# callers can fall back to a real install. macOS/APFS uses cp -c (clonefile);
# Linux btrfs/xfs uses cp --reflink. On other filesystems CoW silently degrades
# to a full copy (correct, just not instant). Used by project_seed_env_files.
clone_dir() {
  local src="$1" dst="$2"
  case "$(uname -s)" in
    Darwin) cp -c -R "$src" "$dst" 2>/dev/null ;;
    *)      cp -R --reflink=auto "$src" "$dst" 2>/dev/null ;;
  esac
}

# ===========================================================================
# >>> PER-PROJECT SECTION: edit everything between here and "END PER-PROJECT".
# The values below are a worked example for a Vite (client) + Express (server)
# Node project. Replace them with your stack's equivalents.
# ===========================================================================

# --- CONFIG -----------------------------------------------------------------
WORKTREES_SUBDIR=".claude/worktrees"   # where envs live (keep as the runtime's
                                       # own worktree dir unless non-Claude
                                       # agents need them elsewhere)
CANONICAL_BRANCH_PREFIX="worktree-"    # must match the runtime's EnterWorktree
                                       # branch prefix so adoption renames
                                       # nothing; verify with `git branch
                                       # --show-current` after an EnterWorktree
PORT_BASE=13000                        # env ports start here (main/takeover = PORT_BASE .. +PORTS_PER_ENV-1).
                                       # MACHINE-GLOBAL: the slot registry dedups ports only
                                       # WITHIN this repo; two repos sharing this base collide
                                       # on localhost. Give each repo a distinct base (stacks.md).
PORT_STRIDE=2                         # spacing between a slot's ports; must be >= PORTS_PER_ENV or
                                       # adjacent slots overlap. Defaults to exactly PORTS_PER_ENV
                                       # (densest, no wasted ports); raise only for headroom.
PORTS_PER_ENV=2                        # distinct localhost ports each env reserves
MAIN_DEV_CMD="npm run dev"             # named in messages and the in-env guard
LOCKFILES="package-lock.json"          # lockfiles whose change in a pull triggers
                                       # project_sync_deps (space-separated, repo-root-
                                       # relative; e.g. "composer.lock package-lock.json")

# --- seed an env's files: dependencies (CoW), lockfile reconcile, local certs
# Deps are the big win: a CoW clone is ~instant and near-zero disk vs. a fresh
# install. Reconcile against the env branch's own lockfile so a branch that
# changed deps still gets them. Do NOT copy secrets that two running servers
# would fight over (e.g. a shared OAuth refresh-token store), let each env
# acquire its own.
project_seed_env_files() {
  local main="$1" env="$2"
  if [[ ! -d "$env/node_modules" ]]; then
    if [[ -d "$main/node_modules" ]]; then
      say "cloning node_modules (copy-on-write)..."
      if ! clone_dir "$main/node_modules" "$env/node_modules"; then
        rm -rf "$env/node_modules"
        warn "clonefile failed; falling back to npm ci (slower)"
        ( cd "$env" && npm ci --no-audit --no-fund )
      fi
    else
      warn "main checkout has no node_modules; running npm ci in the env"
      ( cd "$env" && npm ci --no-audit --no-fund )
    fi
  fi
  if ! cmp -s "$main/package-lock.json" "$env/package-lock.json" 2>/dev/null; then
    say "package-lock.json differs from main; running npm install to reconcile"
    ( cd "$env" && npm install --no-audit --no-fund )
  fi
  # Optional local artifacts (e.g. dev TLS certs). Skip if your stack has none.
  if [[ -d "$main/certs" && ! -d "$env/certs" ]]; then
    clone_dir "$main/certs" "$env/certs" || cp -R "$main/certs" "$env/certs"
  fi
}

# --- reconcile THIS checkout's dependencies after a pull changed a lockfile.
# Run by the post-merge/post-rewrite git hooks (installed by `install-hooks`,
# triggered via `sync-deps`) in whatever checkout pulled — most importantly the
# main checkout, which otherwise ends up with a package.json/composer.lock that
# lists a dependency nobody installed (the recurring trap when an env's PR that
# added a package merges into main). Runs with cwd = repo root. Mirror your
# stack's install command; keep it idempotent (a no-op when already in sync).
# Multi-tool stacks chain commands here, e.g. `composer install && npm install`.
project_sync_deps() {
  npm install --no-audit --no-fund
}

# --- emit the config-file managed-block lines for this env. Args:
#       <env-name> <slot> <port1> <port2> ...
# Use the env name when a value must be unique per env (e.g. a per-env database
# name). Here two distinct ports back three keys (the proxy target is read from
# DEV_API_PORT so it can't collide with a prod-like API_PORT in the base .env).
project_env_port_lines() {
  local name="$1" slot="$2"; shift 2
  local vite_port="$1" api_port="$2"
  printf 'VITE_PORT=%s\n'    "$vite_port"
  printf 'API_PORT=%s\n'     "$api_port"
  printf 'DEV_API_PORT=%s\n' "$api_port"
}

# --- the fixed port set for "takeover QA": serving an env on the main ports so a
# fixed external integration (a sideloaded manifest, an OAuth redirect URI, a
# webhook) that is pinned to those ports exercises the env's branch. Echo
# nothing if your project has no fixed-address integration; --main-ports then
# errors instead of silently doing the wrong thing.
project_main_ports() {
  echo "$PORT_BASE $((PORT_BASE + 1))"
}

# --- launch the env's dev processes in the background, writing one PID file per
# process into .agent-env/. The engine kills every .agent-env/*.pid on stop, so
# the file names are up to you. Run from inside a subshell (the engine sets `set
# -m` so each job gets its own process group and stop can kill whole trees).
project_start_servers() {
  local env="$1" vite_port="$2" api_port="$3"
  cd "$env"
  API_PORT="$api_port" nohup npx tsup src/middle-tier/app.ts --format cjs \
    --out-dir dist --watch --onSuccess "node dist/app.js" \
    >>logs/dev-express.log 2>&1 &
  echo $! >.agent-env/express.pid
  VITE_PORT="$vite_port" DEV_API_PORT="$api_port" nohup npx vite \
    >>logs/dev-vite.log 2>&1 &
  echo $! >.agent-env/vite.pid
}

# --- health checks the engine polls before declaring "up". One per line:
#       label|url|timeout_seconds
project_health_urls() {
  local vite_port="$1" api_port="$2"
  echo "Vite|https://localhost:$vite_port/taskpane.html|60"
  echo "Express|https://localhost:$api_port/api/auth/validate|90"
}

# --- run after files are seeded and ports written. Args: <env-path> <name> <slot>.
# Create/migrate/seed a per-env database, warm a cache, etc. This stack keeps all
# state in remote services, so there is nothing to do. This is the slot for
# stateful-service isolation in other stacks (see references/stacks.md and the
# Laravel worked example in references/laravel.md).
project_after_provision() {
  local env="$1" name="$2" slot="$3"
  :
}

# --- run during `destroy`, after the dirty/unpushed guards pass but before the
# worktree is removed. Args: <env-path> <name> <slot>. Tear down per-env state
# the worktree itself doesn't hold (drop a per-env database, delete a cache
# namespace, etc.). SQLite/file state lives inside the worktree and is removed
# with it, so it needs nothing here. Keep this safe to run more than once.
project_pre_destroy() {
  local env="$1" name="$2" slot="$3"
  :
}

# ===========================================================================
# END PER-PROJECT SECTION. The engine below is stack-agnostic.
# ===========================================================================

MARKER_START="# >>> agent-env managed block >>>"
MARKER_END="# <<< agent-env managed block <<<"

main_root() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "not inside a git repository"
  dirname "$common"
}

# --- the main checkout is NOT necessarily on the default branch --------------
# A person may be working in it, on their own branch, while agents work in envs
# (the human+agent mode). So nothing here infers a branch from what happens to
# be checked out: `create` takes an explicit base ref, and every command that
# reads the main checkout's working tree prints the branch it read, so a wrong
# assumption surfaces in the transcript instead of in someone's diff.
main_branch() {  # <main-root> -> branch name; empty when detached
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

main_state() {  # <main-root> -> "<branch> (clean|dirty)"
  local b d
  b=$(main_branch "$1")
  [[ -n "$b" ]] || b="detached at $(git -C "$1" rev-parse --short HEAD 2>/dev/null || echo '?')"
  if [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]; then d=dirty; else d=clean; fi
  printf '%s (%s)\n' "$b" "$d"
}

# Best guess at this repo's default branch. Used only to make an error message
# actionable on a repo that doesn't call it `main`.
default_branch() {  # <main-root>
  local d
  if d=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
    echo "${d##*/}"; return
  fi
  for d in main master trunk; do
    if git -C "$1" show-ref --verify --quiet "refs/heads/$d"; then echo "$d"; return; fi
  done
  main_branch "$1"
}

# Resolve a name-or-path argument to an absolute env path.
resolve_env() {
  local arg="$1" main="$2"
  if [[ -d "$arg" ]]; then
    ( cd "$arg" && pwd )
  elif [[ -d "$main/$WORKTREES_SUBDIR/$arg" ]]; then
    echo "$main/$WORKTREES_SUBDIR/$arg"
  else
    die "no environment named or located at '$arg' (looked in $WORKTREES_SUBDIR/)"
  fi
}

require_not_main() {
  [[ "$1" != "$2" ]] || die "refusing to operate on the main checkout ($2)"
}

canonical_branch() { printf '%s%s\n' "$CANONICAL_BRANCH_PREFIX" "$1"; }

# Count commits reachable ONLY from $branch (in repo $1): not from any other local
# branch, nor any remote-tracking ref. 0 means deleting the branch loses nothing
# that exists elsewhere. This is the right "is it safe to delete" question, and it
# needs no remote, no fetch, and no assumption the remote is named "origin". It
# also doesn't false-positive when local main is merely ahead of its remote (those
# commits live on `main`, so they're not unique to the env branch).
unique_commits() {  # repo branch
  # NOTE: --exclude takes the BRANCH SHORT NAME (matched against --branches), not
  # a refs/heads/ path; with the full path it matches nothing and the branch gets
  # subtracted from itself, always yielding 0. (Verified against git 2.x.)
  git -C "$1" rev-list --count "refs/heads/$2" \
    --not --exclude="$2" --branches --remotes 2>/dev/null || echo "?"
}

# Ports for a slot: PORTS_PER_ENV consecutive ports starting at PORT_BASE+STRIDE*slot.
ports_for_slot() {
  (( PORT_STRIDE >= PORTS_PER_ENV )) || die "PORT_STRIDE ($PORT_STRIDE) must be >= PORTS_PER_ENV ($PORTS_PER_ENV); adjacent slots would overlap"
  local slot="$1" base=$((PORT_BASE + PORT_STRIDE * slot)) i
  for ((i = 0; i < PORTS_PER_ENV; i++)); do echo $((base + i)); done
}

# ---------------------------------------------------------------------------
# Slot registry: <main>/.agent-env/slots/<name> holds the env's slot number.
# allocate_slot reuses a name's existing slot, else picks the lowest free one.
# destroy frees the slot (see cmd_destroy), so numbers stay low and get reused.
# ---------------------------------------------------------------------------
allocate_slot() {
  local main="$1" name="$2" slots_dir="$1/.agent-env/slots" lock slot used
  mkdir -p "$slots_dir"
  lock="$slots_dir/.lock"
  local tries=0
  until mkdir "$lock" 2>/dev/null; do
    (( ++tries < 50 )) || die "could not acquire slot lock at $lock (stale? rmdir it)"
    sleep 0.1
  done
  if [[ -f "$slots_dir/$name" ]]; then
    slot=$(cat "$slots_dir/$name")
  else
    used=$(cat "$slots_dir"/* 2>/dev/null || true)
    slot=1
    while grep -qx "$slot" <<<"$used"; do slot=$((slot + 1)); done
    echo "$slot" >"$slots_dir/$name"
  fi
  rmdir "$lock" 2>/dev/null || true
  echo "$slot"
}

# ---------------------------------------------------------------------------
# provision: make an existing worktree a complete isolated environment.
# Idempotent: safe to re-run; only fills in what's missing or stale.
# ---------------------------------------------------------------------------
cmd_provision() {
  local main env name slot
  main=$(main_root)
  if [[ $# -ge 1 ]]; then
    env=$(resolve_env "$1" "$main")
  else
    env=$(git rev-parse --show-toplevel) || die "run from inside a worktree or pass a path"
  fi
  require_not_main "$env" "$main"
  name=$(basename "$env")

  # Enforce the canonical branch name here, the one place both creation paths
  # run through, so they converge no matter what each produced. No-op when
  # already canonical (the steady state).
  local want_branch cur_branch
  want_branch=$(canonical_branch "$name")
  cur_branch=$(git -C "$env" rev-parse --abbrev-ref HEAD)
  if [[ "$cur_branch" != "$want_branch" ]]; then
    if git -C "$env" show-ref --verify --quiet "refs/heads/$want_branch"; then
      warn "branch '$want_branch' already exists; leaving worktree on '$cur_branch'"
    else
      git -C "$env" branch -m "$want_branch"
      say "normalized branch: $cur_branch -> $want_branch"
    fi
  fi

  slot=$(allocate_slot "$main" "$name")
  local ports=() p
  while read -r p; do ports+=("$p"); done < <(ports_for_slot "$slot")

  # Seeding copies from the MAIN CHECKOUT's working tree (config file, dependency
  # dirs, credentials), so what lands here depends on the branch checked out
  # there, which is not necessarily the default branch. Say which one it was.
  say "seeding from main checkout on $(main_state "$main")"
  project_seed_env_files "$main" "$env"

  mkdir -p "$env/logs" "$env/.agent-env"

  # Repo-local excludes for the artifacts the engine creates (.agent-env*, and the
  # logs/ dir below). Projects don't necessarily gitignore a top-level logs/, and
  # if any of these read as dirt the destroy guard would refuse. info/exclude lives
  # in the shared common dir, so it applies to ALL worktrees regardless of base ref
  # (git has no per-worktree info/exclude). `/logs/` is anchored so it hides only
  # the env-root logs dir; excludes affect only untracked files, so a project that
  # actually tracks a logs/ is unaffected.
  mkdir -p "$main/.git/info"
  local pat
  for pat in ".agent-env/" ".agent-env.json" "/logs/"; do
    grep -qxF "$pat" "$main/.git/info/exclude" 2>/dev/null || echo "$pat" >>"$main/.git/info/exclude"
  done

  # Config file: copy the main one on first provision, then keep a managed block
  # (always regenerated) holding this env's ports. If your stack writes ports
  # somewhere other than .env, change this region and project_env_port_lines.
  if [[ ! -f "$env/.env" ]]; then
    if [[ -f "$main/.env" ]]; then
      cp "$main/.env" "$env/.env"
    elif [[ -f "$env/.env.example" ]]; then
      say "main has no .env; seeding from .env.example"
      cp "$env/.env.example" "$env/.env"
    else
      warn "no .env or .env.example; creating one with ports only"
      : >"$env/.env"
    fi
  fi
  local stripped
  stripped=$(awk -v s="$MARKER_START" -v e="$MARKER_END" \
    'index($0,s)==1{skip=1} !skip{print} index($0,e)==1{skip=0}' "$env/.env")
  {
    printf '%s\n' "$stripped"
    echo "$MARKER_START"
    echo "# Written by scripts/agent-env.sh, do not edit; re-run provision instead."
    project_env_port_lines "$name" "$slot" "${ports[@]}"
    echo "$MARKER_END"
  } >"$env/.env.tmp"
  # Restrict before the rename, not after: this file lands fresh on every
  # provision, so it would otherwise take the umask default and hand every user
  # on the machine the app key and database credentials.
  chmod 600 "$env/.env.tmp"
  mv "$env/.env.tmp" "$env/.env"

  # Shell-sourceable port facts for serve/stop/list.
  {
    echo "AGENT_ENV_NAME=$name"
    echo "AGENT_ENV_SLOT=$slot"
    echo "AGENT_ENV_PORTS=\"${ports[*]}\""
  } >"$env/.agent-env/ports.env"

  # Machine-readable marker (also the in-env guard's signal).
  local json_ports="${ports[*]}"; json_ports="${json_ports// /, }"
  cat >"$env/.agent-env.json" <<EOF
{
  "name": "$name",
  "slot": $slot,
  "ports": [${json_ports}]
}
EOF

  project_after_provision "$env" "$name" "$slot"

  # Ensure the main checkout has the lockfile-reconcile git hooks (idempotent,
  # quiet). Best-effort: a hook-install hiccup must never fail provisioning.
  cmd_install_hooks --quiet || warn "could not install dependency-sync git hooks"

  say "provisioned '$name' (slot $slot)"
  say "  path:   $env"
  say "  branch: $(git -C "$env" rev-parse --abbrev-ref HEAD)"
  say "  ports:  ${ports[*]}"
  say "  test:   (cd $env && <your test command>)"
  say "  serve:  scripts/agent-env.sh serve $name   # NEVER '$MAIN_DEV_CMD' in an env"
}

# ---------------------------------------------------------------------------
# create: new worktree at <worktrees>/<name> on the canonical branch.
# ---------------------------------------------------------------------------
cmd_create() {
  local name="" base="main" resume=0 main wt branch arg positional=0
  for arg in "$@"; do
    case "$arg" in
      --resume) resume=1 ;;
      -*) die "unknown flag: $arg" ;;
      *)
        case $((++positional)) in
          1) name="$arg" ;;
          2) base="$arg" ;;
          *) die "usage: agent-env.sh create <name> [base-ref] [--resume]" ;;
        esac
        ;;
    esac
  done
  [[ -n "$name" ]] || die "usage: agent-env.sh create <name> [base-ref] [--resume]"
  [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ && ${#name} -le 40 ]] \
    || die "name must be kebab-case ([a-z0-9._-], <=40 chars): got '$name'"
  main=$(main_root)
  wt="$main/$WORKTREES_SUBDIR/$name"
  branch="$(canonical_branch "$name")"
  [[ ! -e "$wt" ]] || die "$wt already exists (use 'provision' to re-provision it)"

  if git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
    if (( resume )); then
      say "resuming existing branch $branch in new worktree $wt"
      git -C "$main" worktree add "$wt" "$branch" --quiet
      cmd_provision "$wt"
      return
    fi
    # A leftover branch from a destroyed env. Merged branches carry no unique
    # work (commits are in main), so recreate-fresh is safe; an unmerged branch
    # needs an explicit decision from the caller.
    local uniq; uniq=$(unique_commits "$main" "$branch")
    if [[ "$uniq" == "0" ]]; then
      say "deleting leftover branch $branch (no unique commits)"
      git -C "$main" branch -D "$branch" >/dev/null
    else
      die "branch $branch already exists with $uniq unique commit(s); rerun with --resume to pick that work back up, or delete the branch first (git branch -D $branch)"
    fi
  elif (( resume )); then
    die "--resume needs an existing branch $branch, but none exists"
  fi

  # The base ref is explicit and is never inferred from the main checkout's HEAD:
  # a person may be sitting on their own branch there, and silently branching an
  # env off their work-in-progress would be a mess to unpick later.
  git -C "$main" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
    || die "base ref '$base' not found; this repo's default branch looks like '$(default_branch "$main")' (usage: agent-env.sh create $name <base-ref>)"
  say "main checkout is on $(main_state "$main")"
  [[ "$(main_branch "$main")" == "$base" ]] \
    || warn "main checkout is not on '$base'; '$name' still branches from '$base' (pass a base-ref to branch from something else)"

  say "creating worktree $wt (branch $branch from $base)"
  git -C "$main" worktree add -b "$branch" "$wt" "$base" --quiet
  cmd_provision "$wt"
}

# ---------------------------------------------------------------------------
# serve / stop: background dev processes with PID files and health checks.
# ---------------------------------------------------------------------------
pid_alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }

any_pid_alive() { # env
  local pidfile
  for pidfile in "$1"/.agent-env/*.pid; do
    [[ -e "$pidfile" ]] || continue
    pid_alive "$pidfile" && return 0
  done
  return 1
}

wait_for_url() { # url label timeout_seconds
  local url="$1" label="$2" deadline=$((SECONDS + $3))
  until curl -k -s -o /dev/null --max-time 2 "$url"; do
    (( SECONDS < deadline )) || { warn "$label did not respond at $url"; return 1; }
    sleep 1
  done
  say "$label is up: $url"
}

cmd_serve() {
  local main env name use_main_ports=0 target="" arg
  main=$(main_root)
  # Flags may appear before or after the name so the wrapper script (e.g.
  # "serve": "agent-env.sh serve --main-ports") can append the name last.
  for arg in "$@"; do
    case "$arg" in
      --main-ports) use_main_ports=1 ;;
      -*) die "unknown flag: $arg" ;;
      *) target="$arg" ;;
    esac
  done
  [[ -n "$target" ]] || die "usage: agent-env.sh serve <name|path> [--main-ports]"
  env=$(resolve_env "$target" "$main")
  require_not_main "$env" "$main"
  [[ -f "$env/.agent-env/ports.env" ]] || die "env not provisioned; run: agent-env.sh provision $env"
  # shellcheck disable=SC1091
  source "$env/.agent-env/ports.env"
  name="$AGENT_ENV_NAME"

  local ports=()
  read -ra ports <<<"$AGENT_ENV_PORTS"
  if (( use_main_ports )); then
    local mp; mp="$(project_main_ports)"
    [[ -n "$mp" ]] || die "--main-ports: this project has no fixed-address takeover QA configured (project_main_ports is empty)"
    read -ra ports <<<"$mp"
  fi

  if any_pid_alive "$env"; then
    say "'$name' is already serving (stop it first to change ports)"
    return 0
  fi

  local port
  for port in "${ports[@]}"; do
    if port_busy "$port"; then
      if (( use_main_ports )); then
        die "port $port is in use; stop the main checkout's dev server ($MAIN_DEV_CMD) before takeover QA. If you did not start it, someone else is working in the main checkout (on $(main_state "$main")); ask before stopping it."
      fi
      die "port $port is in use; is another copy of '$name' or a stale process (agent-env.sh stop $name), or another repo's agent-env sharing PORT_BASE=$PORT_BASE (ports are machine-global)? If a different project owns it, leave it running and give THIS repo a distinct PORT_BASE, then re-provision."
    fi
  done

  say "starting '$name' on ports: ${ports[*]}"
  (
    set -m  # own process group per background job, so stop can kill whole trees
    exec </dev/null  # detach stdin so a watcher can't hold the caller's terminal/pipe
    project_start_servers "$env" "${ports[@]}"
  )

  # On health-check failure, tear the half-started stack back down. Leaving
  # processes + pidfiles behind would make the next serve report "already
  # serving" for an env that never actually came up.
  local label url timeout
  while IFS='|' read -r label url timeout; do
    [[ -n "$url" ]] || continue
    if ! wait_for_url "$url" "$label" "$timeout"; then
      cmd_stop "$env" >/dev/null
      die "'$name' failed to start ($label); processes cleaned up; see $env/logs/"
    fi
  done < <(project_health_urls "${ports[@]}")
  say "logs: $env/logs/"
}

cmd_stop() {
  local main env pidfile pid
  main=$(main_root)
  [[ -n "${1:-}" ]] || die "usage: agent-env.sh stop <name|path>"
  env=$(resolve_env "$1" "$main")
  for pidfile in "$env"/.agent-env/*.pid; do
    [[ -e "$pidfile" ]] || continue
    pid=$(cat "$pidfile")
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
  done
  say "stopped $(basename "$env")"
}

# ---------------------------------------------------------------------------
# list: every worktree with branch / dirty / unpushed / ports / serving.
# ---------------------------------------------------------------------------
cmd_list() {
  local main wt branch dirty uniq ports serving
  main=$(main_root)
  printf 'main checkout: %s  [%s]\n\n' "$main" "$(main_state "$main")"
  printf '%-22s %-32s %-7s %-9s %-13s %s\n' "NAME" "BRANCH" "DIRTY" "UNIQUE" "PORTS" "SERVING"
  git -C "$main" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' |
  while read -r wt; do
    [[ "$wt" != "$main" ]] || continue
    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    dirty=$([[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]] && echo "yes" || echo "no")
    uniq=$(unique_commits "$main" "$branch")
    ports="-"
    [[ -f "$wt/.agent-env/ports.env" ]] && ports=$(awk -F= '/AGENT_ENV_PORTS/{gsub(/"/,"",$2); print $2}' "$wt/.agent-env/ports.env")
    serving="no"
    any_pid_alive "$wt" && serving="yes"
    printf '%-22s %-32s %-7s %-9s %-13s %s\n' "$(basename "$wt")" "$branch" "$dirty" "$uniq" "$ports" "$serving"
  done
}

# ---------------------------------------------------------------------------
# destroy: guarded removal. Refuses to delete work that exists nowhere else.
# ---------------------------------------------------------------------------
cmd_destroy() {
  local main env name branch force=0 uniq arg
  main=$(main_root)
  local target="${1:-}"
  [[ -n "$target" ]] || die "usage: agent-env.sh destroy <name|path> [--force]"
  shift
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      *) die "unknown flag: $arg" ;;
    esac
  done
  env=$(resolve_env "$target" "$main")
  require_not_main "$env" "$main"
  name=$(basename "$env")
  branch=$(git -C "$env" rev-parse --abbrev-ref HEAD)

  cmd_stop "$env" >/dev/null 2>&1 || true

  # Commits that live only on this env branch (no remote/fetch involved).
  uniq=$(unique_commits "$main" "$branch")

  if (( ! force )); then
    if [[ -n "$(git -C "$env" status --porcelain)" ]]; then
      git -C "$env" status --short >&2
      die "'$name' has uncommitted changes; commit & push them, or rerun with --force to discard"
    fi
    if [[ "$uniq" != "0" ]]; then
      die "'$name' has $uniq commit(s) that exist only on $branch; push or merge them, or rerun with --force to discard"
    fi
  fi

  # Stack-specific teardown (e.g. drop a per-env database) now that the guards
  # have passed but the worktree is still present. Failure is non-fatal.
  local slot=""
  [[ -f "$env/.agent-env/ports.env" ]] && slot=$(awk -F= '/^AGENT_ENV_SLOT=/{print $2}' "$env/.agent-env/ports.env")
  project_pre_destroy "$env" "$name" "$slot" || warn "project_pre_destroy reported an error; continuing teardown"

  git -C "$main" worktree remove "$env" 2>/dev/null \
    || git -C "$main" worktree remove --force "$env"  # ignored files (deps etc.) can block plain remove
  git -C "$main" worktree prune

  # A branch with no unique commits carries nothing found nowhere else, so delete
  # it (this is what lets `destroy foo` -> `create foo` reuse the name). A branch
  # with unique commits (only reachable via --force) is kept as the recovery net.
  if [[ "$uniq" == "0" ]]; then
    git -C "$main" branch -D "$branch" >/dev/null && say "deleted branch $branch (no unique commits)"
  else
    say "branch $branch kept ($uniq unique commit(s) recoverable; 'create $name --resume' picks them back up)"
  fi
  # Free the slot so its ports return to the pool; the next new env reuses the
  # lowest free number (no persistence: recreating this name may get new ports).
  rm -f "$main/.agent-env/slots/$name"
  say "destroyed '$name' (slot ${slot:-?} freed)"
}

# run — execute a command IN an env, independent of the shell's cwd. This is the
# mechanical fix for the silent cwd-drift trap: after a restart/resume the agent's
# Bash cwd can reset to the main checkout, so a bare `npm test` / `git diff` runs
# against the wrong tree and reports a false result. `agent-env.sh run <name> -- npm
# test` always runs in the env. exec replaces this shell, so the command's exit code
# and signals pass straight through. Shell features (pipes, inline env) need an
# explicit shell: `run <name> -- bash -lc '...'`.
cmd_run() {
  local main env name
  main=$(main_root)
  name="${1:-}"; [[ -n "$name" ]] || die "usage: agent-env.sh run <name|path> -- <command...>"
  shift
  [[ "${1:-}" == "--" ]] && shift   # optional separator
  [[ $# -gt 0 ]] || die "run: no command given (agent-env.sh run <name> -- <command...>)"
  env=$(resolve_env "$name" "$main")
  cd "$env" && exec "$@"
}

# ---------------------------------------------------------------------------
# Dependency-sync git hooks. After a merge/pull/rebase that changes a lockfile,
# reconcile the checkout's installed dependencies, so a branch that added a
# package (typically merged from an env's PR) can't leave the main checkout with
# a manifest listing a dependency nobody installed. The hooks are generic across
# stacks: they just call back into `sync-deps`, which runs the per-project
# project_sync_deps. So adapting to a new stack means filling project_sync_deps +
# LOCKFILES in the per-project section, nothing here.
# ---------------------------------------------------------------------------

# Write a hook script (post-merge / post-rewrite share one body) that delegates
# to `sync-deps`. Robust to cwd and to a moved checkout via show-toplevel.
write_git_hook() {  # dest-path
  cat >"$1" <<'HOOK'
#!/bin/sh
# Installed by scripts/agent-env.sh (install-hooks). After a merge/pull/rebase
# that changed a lockfile, reconcile this checkout's dependencies so the manifest
# can't list a package nobody installed. The actual install is the per-project
# section's project_sync_deps; this just delegates so the logic lives in one place.
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -x "$root/scripts/agent-env.sh" ] || exit 0
exec "$root/scripts/agent-env.sh" sync-deps
HOOK
  chmod +x "$1"
}

# install-hooks: drop the post-merge + post-rewrite hooks into the MAIN checkout
# and point core.hooksPath at them (both are repo-global: shared across worktrees
# via the common git dir). Idempotent. `--quiet` suppresses info output (used by
# provision so setup happens even if the explicit step was skipped).
cmd_install_hooks() {
  local quiet="" main hooks_dir cur
  [[ "${1:-}" == "--quiet" || "${1:-}" == "-q" ]] && quiet=1
  main=$(main_root)
  hooks_dir="$main/.githooks"
  mkdir -p "$hooks_dir"
  write_git_hook "$hooks_dir/post-merge"
  write_git_hook "$hooks_dir/post-rewrite"
  cur=$(git -C "$main" config --local --get core.hooksPath 2>/dev/null || true)
  case "$cur" in
    ""|".git/hooks"|"$main/.git/hooks")
      git -C "$main" config core.hooksPath .githooks
      [[ -n "$quiet" ]] || say "git hooks installed (.githooks); core.hooksPath set"
      ;;
    ".githooks") : ;;  # already active
    *)
      warn "core.hooksPath is '$cur'; wrote .githooks/{post-merge,post-rewrite} but left it unchanged — activate by setting core.hooksPath=.githooks or chaining the hooks from your existing hooks dir" ;;
  esac
  if [[ -z "$quiet" ]] && ! git -C "$main" ls-files --error-unmatch .githooks/post-merge >/dev/null 2>&1; then
    say "commit .githooks/ so worktrees and collaborators inherit the dependency-sync hook"
  fi
}

# sync-deps: if a watched lockfile ($LOCKFILES) changed in the merge/pull/rebase
# that just finished (ORIG_HEAD..HEAD), run project_sync_deps. Called by the git
# hooks; safe to run by hand. No ORIG_HEAD (fresh clone, no prior op) -> no-op.
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

usage() {
  sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

cmd="${1:-}"
[[ -n "$cmd" ]] && shift || usage
case "$cmd" in
  create)    cmd_create "$@" ;;
  provision) cmd_provision "$@" ;;
  run)       cmd_run "$@" ;;
  serve)     cmd_serve "$@" ;;
  stop)      cmd_stop "$@" ;;
  list)      cmd_list "$@" ;;
  destroy)   cmd_destroy "$@" ;;
  install-hooks) cmd_install_hooks "$@" ;;
  sync-deps) cmd_sync_deps "$@" ;;
  *)         usage ;;
esac
