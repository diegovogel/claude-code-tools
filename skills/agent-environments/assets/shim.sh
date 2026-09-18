#!/usr/bin/env bash
# Agent-environment shim for __PROJECT__. This is the whole in-repo footprint of
# the agent-environments skill: the engine lives at
# ~/.claude/skills/agent-environments/assets/__ENGINE__ and this project's env
# config at ~/.claude/agent-environments/__PROJECT__/project.sh. Change env
# behavior THERE, never here; this shim is committed once and never changes.
set -euo pipefail
AGENT_ENV_PROJECT="__PROJECT__"

# `guard` is answered here, without the engine, so the dev command keeps working
# on a machine without the skill. An env is a linked git worktree (.git is a
# FILE, in the generic and the WordPress flow alike; a submodule checkout has one
# too, which none of these repos is) and the generic engine also leaves an
# .agent-env.json marker. npm and composer run scripts with cwd = the package
# root, which is what makes the .git check valid.
if [[ "${1:-}" == "guard" ]]; then
  if [[ -f .agent-env.json || -f .git ]]; then
    printf '\n\033[31m\xe2\x9c\x96 the main dev command is disabled inside an agent environment.\033[0m\n' >&2
    printf "  It is pinned to the main checkout's ports and would collide with its dev server.\n\n" >&2
    printf '  Use instead:\n    ./scripts/%s serve <name>   # live server on this env'"'"'s own ports\n' "$(basename "$0")" >&2
    printf '    the test and build commands       # most tasks need only these\n\n' >&2
    exit 1
  fi
  exit 0
fi

engine="${AGENT_ENV_ENGINE:-$HOME/.claude/skills/agent-environments/assets/__ENGINE__}"
if [[ ! -x "$engine" ]]; then
  # The committed git hooks call sync-deps after every merge or rebase; without
  # the skill there is nothing to reconcile, and a hook must not nag on each pull.
  [[ "${1:-}" == "sync-deps" ]] && exit 0
  echo "agent-env: engine not found or not executable: $engine" >&2
  echo "agent-env: this repo's agent environments need the agent-environments skill on this machine (see CLAUDE.md); nothing else in the project depends on it" >&2
  exit 1
fi
export AGENT_ENV_PROJECT AGENT_ENV_SHIM="$0"
exec "$engine" "$@"
