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

worktrees="$root/.claude/worktrees"
[[ -d "$worktrees" ]] || exit 0

names=()
for d in "$worktrees"/*/; do
  [[ -f "${d}.agent-env.json" ]] && names+=("$(basename "$d")")
done
[[ ${#names[@]} -gt 0 ]] || exit 0

printf 'Agent environments are provisioned in this repo: %s.\n' "${names[*]}"
printf 'After a restart/resume the Bash cwd can silently reset to the main checkout, so a bare npm/git command may run against the wrong tree. Run env verification cwd-independently: scripts/agent-env.sh run <name> -- <cmd> (e.g. scripts/agent-env.sh run %s -- npm test). If you must run something run cannot wrap, check pwd and git branch --show-current first.\n' "${names[0]}"
exit 0
