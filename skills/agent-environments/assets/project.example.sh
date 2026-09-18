#!/usr/bin/env bash
# Per-project config for the agent-environments engine (generic flow).
#
# Lives OUTSIDE the repo at ~/.claude/agent-environments/<project>/project.sh,
# where <project> is the repo directory's basename (the name the repo's shim,
# scripts/agent-env.sh, carries in AGENT_ENV_PROJECT). The engine at
# ~/.claude/skills/agent-environments/assets/agent-env.sh sources it under
# `set -euo pipefail` after setting its defaults, so a config only has to state
# what differs, and a config that restates everything (like this one) works too.
# Top-level statements are fine (extend PATH, define a helper).
#
# Required: PORT_BASE, PORTS_PER_ENV, project_seed_env_files,
# project_env_port_lines, project_start_servers. Everything else has a default
# in the engine: WORKTREES_SUBDIR, CANONICAL_BRANCH_PREFIX, PORT_STRIDE (empty =
# PORTS_PER_ENV), LOCKFILES (empty), MAIN_DEV_CMD, and no-op project_sync_deps,
# project_main_ports, project_health_urls, project_after_provision,
# project_pre_destroy. say/warn/die/clone_dir are the engine's and can be used.
#
# The values below are a worked example for a Vite (client) + Express (server)
# Node project. Replace them with your stack's equivalents: the skill's
# references/stacks.md for per-knob guidance, references/laravel.md for a
# complete Laravel/PHP fill-in.

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
# triggered via `sync-deps`) in whatever checkout pulled, most importantly the
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
