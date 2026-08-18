#!/usr/bin/env bash
# SessionStart hook: when provisioned agent-envs exist, remind the agent to run
# verification through `agent-env.sh run <name> -- <cmd>`. After a restart/resume
# the Bash cwd can silently reset to the main checkout, so a bare `npm test` /
# `git diff` can run against the wrong tree and report a false result (a green
# suite for code you didn't change, an empty `main...HEAD` diff). The `run`
# subcommand sidesteps that by `cd`-ing into the env first; this hook surfaces it
# at session start so a resumed session sees the mechanical re-anchor path.
#
# Project-agnostic: wire it into a project's SessionStart hook (see SKILL.md). It
# is self-contained, prints nothing when no envs exist (non-env sessions stay
# quiet), and ALWAYS exits 0 — a SessionStart hook must never block startup.
set -euo pipefail

# Main checkout root = parent of the shared git dir; fall back to cwd.
if root=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  root=$(dirname "$root")
else
  root="$PWD"
fi

# Two layouts. The generic engine keeps each env's worktree (and its
# .agent-env.json marker) under .claude/worktrees/. The WordPress flow's
# worktrees live OUTSIDE the repo, nested in a cloned install, so its envs are
# detectable only by their metadata dir here. Check both, or this hook is a
# permanent no-op for exactly the WP repos that need it.
names=()
script="scripts/agent-env.sh"
for d in "$root"/.claude/worktrees/*/; do
  [[ -f "${d}.agent-env.json" ]] && names+=("$(basename "$d")")
done
if [[ ${#names[@]} -eq 0 ]]; then
  for d in "$root"/.agent-env/wp/*/; do
    [[ -f "${d}meta.env" ]] && names+=("$(basename "$d")")
  done
  [[ ${#names[@]} -eq 0 ]] || script="scripts/agent-env-wp.sh"
fi
[[ ${#names[@]} -gt 0 ]] || exit 0

printf 'Agent environments are provisioned in this repo: %s.\n' "${names[*]}"
printf 'After a restart/resume the Bash cwd can silently reset to the main checkout, so a bare test/git command may run against the wrong tree. Run env verification cwd-independently: %s run <name> -- <cmd> (e.g. %s run %s -- <test command>). If you must run something run cannot wrap, check pwd and git branch --show-current first.\n' "$script" "$script" "${names[0]}"

# The main checkout is not necessarily on the default branch: in the human+agent
# mode a person works there, on their own branch, while agents work in envs.
# State it, so no session has to assume it (or interrupt them to ask).
branch=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "a detached HEAD")
if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
  state="uncommitted changes present"
else
  state="clean"
fi
printf 'The main checkout (%s) is on branch %s, %s. Never assume it is on the default branch, and treat it as possibly occupied: someone may be working there, so do not switch branches, stash, or clean in it without asking, and do not take its dev-server ports (takeover QA) without asking.\n' "$root" "$branch" "$state"
exit 0
