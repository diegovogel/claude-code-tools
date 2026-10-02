#!/usr/bin/env bash
#
# teardown.sh — remove a merged agent env and bring its repos' base branch up to date.
#
# Usage: teardown.sh <env-name> <main-checkout>
#
# <main-checkout> is env-status.sh's "main". Each repo's base branch is worked out
# the way env-status.sh does it (after the merge, that's the merged PR's base).
#
# Run it from OUTSIDE the env (after ExitWorktree), once the env's PRs are merged.
#
#   standard / wordpress  runs the project's guarded `destroy`. When destroy refuses
#                         because the branch's commits exist nowhere else (a squash
#                         or rebase merge rewrites them), it checks that everything
#                         on the branch is in the base by content, and only then
#                         reruns destroy --force and deletes the branch(es).
#   lightweight (no engine, e.g. a Shopify theme)
#                         removes the worktree and its branch the same guarded way.
#                         Stop the env's dev server before running this.
#
# Then, in each repo's main checkout, fast-forwards the base branch to origin's:
# in place when it's checked out, or, when another branch is (someone's working
# there), without checking it out.
#
# Exit codes: 0 done (warnings on stderr); 1 refused, nothing removed (reason on
# stderr); 6 usage or tool error.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ew_need git gh

[[ $# -eq 2 ]] || ew_die 6 "usage: $(basename "$0") <env-name> <main-checkout>"
name="$1"
main=$(cd "$2" && pwd -P) || ew_die 6 "no such directory: $2"
[[ "$(ew_main_checkout "$main")" == "$main" ]] || ew_die 6 "$2 is not a repo's main checkout"

flavor=$(ew_flavor "$main")
wt=$(ew_worktree_for_branch "$main" "worktree-$name")
[[ -n "$wt" ]] || wt=$(ew_worktree_named "$main" "$name")
if [[ -n "$wt" ]]; then
  branch=$(git -C "$wt" branch --show-current)
else
  branch="worktree-$name"
fi
[[ -n "$branch" ]] || ew_die 6 "the env's worktree has a detached HEAD; check out its branch first"

# Collect the repos and their base branches before destroy: a WordPress env's
# list lives in files destroy removes, and the branch's reflog goes with it.
repo_lines=""
while IFS=$'\t' read -r dir rmain; do
  slug=$(ew_slug "$rmain") || ew_die 6 "gh can't resolve the GitHub repo for $rmain"
  git -C "$rmain" fetch --quiet --prune origin || ew_die 6 "git fetch failed in $rmain"
  base=$(ew_base_for "$rmain" "$slug" "$branch") || ew_die 6 "can't work out the base branch for $rmain"
  repo_lines="$repo_lines$dir"$'\t'"$rmain"$'\t'"${base%% *}"$'\n'
done < <(ew_env_repos "$main" "$name" "$branch" "$flavor")
repo_lines="${repo_lines%$'\n'}"

here=$(pwd -P)
while IFS=$'\t' read -r dir rmain base; do
  [[ "$dir" == "$rmain" ]] && continue
  d=$(cd "$dir" 2>/dev/null && pwd -P) || continue
  [[ "$here" != "$d" && "$here" != "$d"/* ]] \
    || ew_die 6 "run this from outside the env (ExitWorktree with action keep, then from $main)"
done <<<"$repo_lines"

say() { echo "teardown $name: $*" >&2; }

# Every repo's branch is clean and fully in its base, by content.
all_content_merged() {
  local dir rmain base ref
  while IFS=$'\t' read -r dir rmain base; do
    worktree_clean "$dir" "$rmain" || return 1
    ref=$(ew_branch_ref "$rmain" "$branch")
    [[ -z "$ref" ]] && continue
    # Nothing to lose when no commit exists only on this branch (an env that
    # changed nothing in this repo, say); else the base must have it all.
    [[ "$(git -C "$rmain" rev-list --count "$ref" --not --exclude="$branch" --branches --remotes)" != 0 ]] || continue
    if ! ew_content_merged "$rmain" "$base" "$ref"; then
      say "$branch in $rmain has changes that $base lacks"
      return 1
    fi
  done <<<"$repo_lines"
}

# A worktree whose status can't be read counts as dirty, not clean.
worktree_clean() { # dir repo-main
  local status
  [[ "$1" != "$2" ]] || return 0
  if ! status=$(git -C "$1" status --porcelain 2>/dev/null); then
    say "can't read git status in $1"
    return 1
  fi
  [[ -z "$status" ]] || { say "$1 has uncommitted changes"; return 1; }
}

delete_local_branches() {
  local dir rmain base
  while IFS=$'\t' read -r dir rmain base; do
    if git -C "$rmain" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
      git -C "$rmain" branch -D "$branch" >/dev/null && say "deleted branch $branch in $rmain (its content is in the base)"
    fi
  done <<<"$repo_lines"
}

case "$flavor" in
  standard | wordpress)
    [[ "$flavor" == standard ]] && shim="$main/scripts/agent-env.sh" || shim="$main/scripts/agent-env-wp.sh"
    set +e
    out=$(cd "$main" && "$shim" destroy "$name" 2>&1)
    rc=$?
    set -e
    printf '%s\n' "$out" >&2
    if ((rc != 0)); then
      if grep -Eq 'commit\(s\) (that exist )?only on' <<<"$out"; then
        all_content_merged || ew_die 1 "destroy refused and the branch isn't fully merged; nothing removed"
        say "destroy refused over rewritten commits (squash or rebase merge), but the base has all of it; forcing"
        (cd "$main" && "$shim" destroy "$name" --force) >&2 || ew_die 1 "destroy --force failed"
        delete_local_branches
      else
        ew_die 1 "destroy failed (see above)"
      fi
    fi
    ;;
  lightweight)
    if [[ -n "$wt" ]]; then
      worktree_clean "$wt" "$main" || ew_die 1 "nothing removed"
      all_content_merged || ew_die 1 "the branch isn't fully merged; nothing removed"
      # Ignored files (CLI state, caches) block a plain remove; the tree is clean.
      git -C "$main" worktree remove "$wt" 2>/dev/null || git -C "$main" worktree remove --force "$wt"
      git -C "$main" worktree prune
      say "removed worktree $wt"
    else
      all_content_merged || ew_die 1 "the branch isn't fully merged; nothing removed"
    fi
    delete_local_branches
    ;;
esac

# Bring each repo's base branch up to date in its main checkout.
while IFS=$'\t' read -r dir rmain base; do
  current=$(git -C "$rmain" branch --show-current)
  if [[ "$current" == "$base" ]]; then
    # Fetched above; merging origin's copy needs no upstream configured.
    if git -C "$rmain" merge --ff-only --quiet "refs/remotes/origin/$base"; then
      say "$rmain: $base is up to date ($(git -C "$rmain" rev-parse --short HEAD))"
    else
      say "warning: $rmain: $base couldn't be fast-forwarded to origin's; update it by hand"
    fi
  elif ! git -C "$rmain" rev-parse --verify -q "refs/heads/$base" >/dev/null; then
    say "$rmain has no local $base branch; nothing to update"
  elif git -C "$rmain" fetch --quiet origin "$base:$base"; then
    say "$rmain is on ${current:-a detached HEAD}, so $base was fast-forwarded without checking it out"
  else
    say "warning: $rmain is on ${current:-a detached HEAD} and $base couldn't be fast-forwarded; left as is"
  fi
done <<<"$repo_lines"
