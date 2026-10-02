#!/usr/bin/env bash
#
# env-status.sh — what an agent env still needs before it can be torn down.
#
# Usage: env-status.sh [<env-name>]
#
# Run it from inside one of the env's worktrees (no name needed), or from anywhere
# in the repo with the env's name. It fetches each repo the env spans (a WordPress
# env can span a theme and a plugin), then prints one JSON object:
#
#   {"name", "branch", "main", "flavor": "standard|wordpress|lightweight",
#    "repos": [{"dir", "main", "slug", "base", "base_source", "default_branch",
#               "started_from", "worktree", "dirty", "unpushed", "remote_branch",
#               "content_merged", "own_commits", "open_prs", "merged_prs", "action"}]}
#
# "main" is the main checkout of the repo that created the env (for a WordPress
# env, the theme or plugin whose registry lists it): pass it to teardown.sh.
#
# "base" is the branch the work merges into, per repo ("base_source" says why):
# the open PR's base ("open-pr"); else the base its last merged PR used
# ("merged-pr"); else the branch the env started from, when origin has it
# ("started-from"; a WordPress env starts from whatever its checkout had checked
# out); else the repo's default branch ("default"). "started_from" is
# {"ref", "sha"}, from the branch's reflog, or null once that's gone (git gc can
# expire it after about a month). "own_commits" counts the commits the branch
# adds beyond its start (with no start record: those on no other branch).
#
# "action" per repo, in priority order:
#   blocked-dirty  uncommitted changes in the worktree
#   multiple-prs   more than one open PR from the branch; ask which to merge
#   merge          one open PR (push first when "unpushed" > 0)
#   cleanup        already merged ("merged_prs"[0]), but the remote branch is still
#                  there; merge-when-green.sh on that PR deletes it
#   nothing        everything on the branch is already in the base, or the env
#                  made no commits in this repo since it started
#   unknown-base   the env started from a commit the base doesn't have (the
#                  checkout's unpushed work, or a branch origin doesn't have), so a
#                  PR into the base would carry that too; ask which base to use.
#                  With "started_from" null, this means the branch carries commits
#                  the base lacks that another branch also has
#   create-pr      the branch carries changes the base lacks and has no open PR
#                  (when "merged_prs" isn't empty, an earlier PR already merged:
#                  merge origin/<base> in first, so the new PR shows only new work)
#
# Exit codes: 0 status printed; 6 usage, environment or tool error.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ew_need git gh jq

[[ $# -le 1 && "${1:-}" != -* ]] || ew_die 6 "usage: $(basename "$0") [<env-name>]"
name="${1:-}"

main=$(ew_main_checkout "$PWD") || ew_die 6 "not inside a git repo: $PWD"

if [[ -n "$name" ]]; then
  wt=$(ew_worktree_for_branch "$main" "worktree-$name")
  [[ -n "$wt" ]] || wt=$(ew_worktree_named "$main" "$name")
  if [[ -n "$wt" ]]; then
    branch=$(git -C "$wt" branch --show-current)
  else
    branch="worktree-$name" # worktree already gone; engine envs use this branch name
  fi
else
  top=$(git rev-parse --show-toplevel)
  [[ "$top" != "$main" ]] || ew_die 6 "this is the main checkout, not an env; pass the env's name"
  branch=$(git branch --show-current)
  # Engine envs are always on worktree-<name>; a WordPress env's worktree is
  # named after the theme or plugin, so only the branch carries the env's name.
  case "$branch" in
    worktree-?*) name="${branch#worktree-}" ;;
    *) name=$(basename "$top") ;;
  esac
fi
[[ -n "$branch" ]] || ew_die 6 "the env's worktree has a detached HEAD; check out its branch first"

# A WordPress env is recorded under the repo that created it, which needn't be
# the one this session sits in.
owner=$(ew_wp_owner "$main" "$name")
if [[ -f "$owner/.agent-env/wp/$name/meta.env" ]]; then
  main="$owner"
  flavor=wordpress
else
  flavor=$(ew_flavor "$main")
fi

repo_json() { # dir repo-main
  local dir="$1" rmain="$2" slug default base source worktree=false dirty=false unpushed=0 remote=false
  local ref merged=false prs count merged_prs start started='null' start_ok=true own total action status

  # Explicit checks throughout: bash may run a function in $(...) without set -e.
  slug=$(ew_slug "$dir") || ew_die 6 "gh can't resolve the GitHub repo for $dir"
  default=$(ew_default_branch "$slug") || ew_die 6 "can't read the default branch of $slug"
  git -C "$dir" fetch --quiet --prune origin || ew_die 6 "git fetch failed in $dir"
  prs=$(gh pr list --repo "$slug" --head "$branch" --state open \
    --json number,url,isDraft,baseRefName,headRefOid) || ew_die 6 "can't list $slug's PRs"
  merged_prs=$(gh pr list --repo "$slug" --head "$branch" --state merged --limit 5 \
    --json number,url,baseRefName,mergedAt) || ew_die 6 "can't list $slug's merged PRs"
  count=$(jq 'length' <<<"$prs")

  if ((count == 1)); then
    base=$(jq -r '.[0].baseRefName' <<<"$prs")
    source=open-pr
  else
    base=$(ew_base_for "$dir" "$slug" "$branch") || ew_die 6 "can't work out the base branch for $dir"
    source="${base#* }"
    base="${base%% *}"
  fi
  git -C "$dir" rev-parse --verify -q "refs/remotes/origin/$base" >/dev/null \
    || ew_die 6 "$slug has no branch $base on origin"

  if [[ "$(git -C "$dir" branch --show-current)" == "$branch" && "$dir" != "$rmain" ]]; then
    worktree=true
    status=$(git -C "$dir" status --porcelain) || ew_die 6 "can't read git status in $dir"
    [[ -z "$status" ]] || dirty=true
  fi
  git -C "$dir" rev-parse --verify -q "refs/remotes/origin/$branch" >/dev/null && remote=true
  if git -C "$dir" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
    if [[ "$remote" == true ]]; then
      unpushed=$(git -C "$dir" rev-list --count "refs/remotes/origin/$branch..refs/heads/$branch") \
        || ew_die 6 "can't count unpushed commits in $dir"
    else
      unpushed=$(git -C "$dir" rev-list --count "refs/remotes/origin/$base..refs/heads/$branch") \
        || ew_die 6 "can't count unpushed commits in $dir"
    fi
  fi

  ref=$(ew_branch_ref "$dir" "$branch")
  if [[ -z "$ref" ]] || ew_content_merged "$dir" "$base" "$ref"; then
    merged=true
  fi

  # What the env started from must already be in the base, or a PR would carry
  # someone's unmerged work along with the env's own. With no record of the start,
  # commits the base lacks that another branch has give it away instead.
  start=$(ew_branch_start "$dir" "$branch")
  own=$(ew_own_commits "$dir" "$branch" "$base" "${start%% *}") || ew_die 6 "git rev-list failed in $dir"
  if [[ -n "$start" ]]; then
    started=$(jq -nc --arg sha "${start%% *}" --arg ref "${start#* }" '{ref: $ref, sha: $sha}')
    ew_content_merged "$dir" "$base" "${start%% *}" || start_ok=false
  elif [[ -n "$ref" ]]; then
    total=$(git -C "$dir" rev-list --count "refs/remotes/origin/$base..$ref") || ew_die 6 "git rev-list failed in $dir"
    ((total == own)) || start_ok=false
  fi

  if [[ "$dirty" == true ]]; then
    action=blocked-dirty
  elif ((count > 1)); then
    action=multiple-prs
  elif ((count == 1)); then
    action=merge
  elif [[ "$merged" == true ]]; then
    if [[ "$remote" == true && "$merged_prs" != "[]" ]]; then
      action=cleanup
    else
      action=nothing
    fi
  elif [[ -n "$start" ]] && ((own == 0)); then
    action=nothing # the env made no commits here; what differs is someone else's
  elif [[ "$start_ok" == false ]]; then
    action=unknown-base
  else
    action=create-pr
  fi

  jq -n --arg dir "$dir" --arg main "$rmain" --arg slug "$slug" --arg base "$base" \
    --arg source "$source" --arg default "$default" --argjson started "$started" \
    --argjson worktree "$worktree" --argjson dirty "$dirty" --argjson unpushed "$unpushed" \
    --argjson remote "$remote" --argjson merged "$merged" --argjson prs "$prs" \
    --argjson merged_prs "$merged_prs" --argjson own "$own" --arg action "$action" \
    '{dir: $dir, main: $main, slug: $slug, base: $base, base_source: $source,
      default_branch: $default, started_from: $started, worktree: $worktree, dirty: $dirty,
      unpushed: $unpushed, remote_branch: $remote, content_merged: $merged, own_commits: $own,
      open_prs: $prs, merged_prs: $merged_prs, action: $action}'
}

repos="[]"
while IFS=$'\t' read -r dir rmain; do
  # A separate assignment, so a failure inside repo_json exits with its own code.
  repo=$(repo_json "$dir" "$rmain")
  repos=$(jq --argjson r "$repo" '. + [$r]' <<<"$repos")
done < <(ew_env_repos "$main" "$name" "$branch" "$flavor")

jq -n --arg name "$name" --arg branch "$branch" --arg main "$main" --arg flavor "$flavor" \
  --argjson repos "$repos" \
  '{name: $name, branch: $branch, main: $main, flavor: $flavor, repos: $repos}'
