#!/usr/bin/env bash
# Per-project config for the agent-environments WordPress engine.
#
# Lives OUTSIDE the repo at ~/.claude/agent-environments/<project>/project.sh,
# where <project> is the theme/plugin repo directory's basename (the name the
# repo's shim, scripts/agent-env-wp.sh, carries in AGENT_ENV_PROJECT). The engine
# at ~/.claude/skills/agent-environments/assets/agent-env-wp.sh sources it under
# `set -euo pipefail` after setting its defaults, so a config only has to state
# what differs, and a config that restates everything (like this one) works too.
# Top-level statements are fine (extend PATH, define a helper).
#
# Required: PORT_BASE. Everything else has a default in the engine, equal to the
# values below: ENV_PARENT, PORT_STRIDE (empty = PORTS_PER_ENV), PORTS_PER_ENV,
# CANONICAL_BRANCH_PREFIX, WP, WP_SERVER_WORKERS, WEB_HOST, URL_MODE, LOCKFILES,
# SYNC_PATHS, SIBLING_REPOS, project_after_worktree, project_sync_deps.
# say/warn/die/clone_dir are the engine's and can be used.

# Where full-install clones live. Keep it OUT of any Herd/Valet parked path so
# the clones don't get auto-served as <name>.test; we serve them via wp server.
ENV_PARENT="$HOME/WebDev/Sites/.wp-agent-envs"
PORT_BASE=18300                 # slot N -> PORT_BASE + PORT_STRIDE*N
PORT_STRIDE=2                   # >= PORTS_PER_ENV (the floor); densest packing.
                                # Every config sharing ENV_PARENT must use the SAME
                                # stride: the pool's slot math is (port-base)/stride.
PORTS_PER_ENV=2                 # wp server + (optional) asset dev/watch server. A
                                # worktree's wp-env takes a slot of its own (see
                                # setup_wp_env), so this also has to cover wp-env's
                                # two ports (development + tests); keep it >= 2.
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
                                # WEB address only: the engine's mysql -h stays
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
# Additional paths whose change in a pull ALSO triggers project_sync_deps. An
# entry ending in "/" matches anything beneath it; anything else is an exact
# path, like LOCKFILES. Space-separated, repo-root-relative.
#
# For sources whose BUILD OUTPUT is gitignored -- compiled CSS is the usual case.
# A lockfile is not the only thing a merge can invalidate: pull in an scss change
# and the checkout serves CSS built from sources it no longer has, with nothing to
# notice. e.g. SYNC_PATHS="scss/"
SYNC_PATHS=""
# Other custom repos in this install that every env should branch alongside this
# one (space-separated, install-relative, e.g. "wp-content/plugins/my-plugin").
# The canonical case is a custom theme plus a custom plugin: each repo's
# config lists the OTHER. create gives each sibling a worktree on the same
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
