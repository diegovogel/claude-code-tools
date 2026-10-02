# lib.sh — helpers shared by the environment-wrapup scripts. Source it; don't run it.
#
# Written for macOS's bash 3.2: no associative arrays, no mapfile.

# Append (never prepend) the usual tool dirs, so CLIs resolve the way they do in
# the user's own shell.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"

ew_die() { # exit-code message...
  local code="$1"; shift
  echo "error: $*" >&2
  exit "$code"
}

ew_need() { # command...
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || ew_die 6 "$c is not on PATH"
  done
}

# The main checkout of the repo containing $1. A linked worktree resolves to the
# checkout it was created from.
ew_main_checkout() { # dir
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  dirname "$common"
}

# The worktree checked out on branch $2, in the repo whose main checkout is $1.
# Prints nothing when no worktree has it. The awk reads to the end rather than
# exiting at the match, which under pipefail could fail git with SIGPIPE.
ew_worktree_for_branch() { # main branch
  git -C "$1" worktree list --porcelain | awk -v ref="refs/heads/$2" '
    /^worktree / { path = substr($0, 10) }
    $0 == "branch " ref && !found { print path; found = 1 }'
}

# The linked worktree whose directory is named $2 (the main checkout itself never matches).
ew_worktree_named() { # main name
  git -C "$1" worktree list --porcelain | awk -v name="$2" -v main="$1" '
    /^worktree / {
      path = substr($0, 10); n = split(path, parts, "/")
      if (path != main && parts[n] == name && !found) { print path; found = 1 }
    }'
}

# The main checkout that created WordPress env $2. A session can sit in a sibling
# repo's worktree, whose main checkout has no record of the env, so look through
# the site's other theme and plugin checkouts for the one that has. Prints $1 when
# none does.
ew_wp_owner() { # main name
  local wproot d
  if [[ ! -f "$1/.agent-env/wp/$2/meta.env" ]] && wproot=$(ew_wp_root "$1"); then
    for d in "$wproot"/wp-content/themes/* "$wproot"/wp-content/plugins/*; do
      if [[ -f "$d/.agent-env/wp/$2/meta.env" ]]; then
        ew_main_checkout "$d" && return 0
      fi
    done
  fi
  echo "$1"
}

# standard (scripts/agent-env.sh), wordpress (scripts/agent-env-wp.sh), or
# lightweight (no engine, e.g. a Shopify theme).
ew_flavor() { # main
  if [[ -f "$1/scripts/agent-env-wp.sh" ]]; then
    echo wordpress
  elif [[ -f "$1/scripts/agent-env.sh" ]]; then
    echo standard
  else
    echo lightweight
  fi
}

# The repos an env spans, one per line as "<dir><TAB><main checkout>": the env's
# own repo first, then, for a WordPress env, each sibling repo its meta.env lists.
# <dir> is the env's worktree, or the main checkout once the worktree is gone.
ew_env_repos() { # main name branch flavor
  local main="$1" name="$2" branch="$3" flavor="$4" wt
  wt=$(ew_worktree_for_branch "$main" "$branch")
  printf '%s\t%s\n' "${wt:-$main}" "$main"

  [[ "$flavor" == wordpress ]] || return 0
  local meta="$main/.agent-env/wp/$name/meta.env" install siblings wproot s swt
  [[ -f "$meta" ]] || return 0
  # Read the two values rather than sourcing the file: it is shell, written by
  # another script, and nothing else from it is needed here.
  install=$(sed -n 's/^AGENT_ENV_INSTALL="\(.*\)"$/\1/p' "$meta")
  siblings=$(sed -n 's/^AGENT_ENV_SIBLINGS="\(.*\)"$/\1/p' "$meta")
  [[ -n "$siblings" ]] || return 0
  wproot=$(ew_wp_root "$main") || return 0
  for s in $siblings; do
    [[ -e "$wproot/$s/.git" ]] || continue
    swt="$install/$s"
    if [[ -f "$swt/.git" ]]; then
      printf '%s\t%s\n' "$swt" "$wproot/$s"
    else
      printf '%s\t%s\n' "$wproot/$s" "$wproot/$s"
    fi
  done
}

# The WordPress install holding $1: the nearest ancestor with a wp-config.php.
ew_wp_root() { # dir
  local d
  d=$(cd "$1" && pwd) || return 1
  while [[ "$d" != "/" ]]; do
    [[ -f "$d/wp-config.php" ]] && { echo "$d"; return 0; }
    d=$(dirname "$d")
  done
  return 1
}

# owner/repo of the GitHub repo that $1's PRs go to, as gh resolves it.
ew_slug() { # dir
  (cd "$1" && gh repo view --json nameWithOwner --jq .nameWithOwner)
}

ew_default_branch() { # owner/repo
  gh repo view "$1" --json defaultBranchRef --jq .defaultBranchRef.name
}

# True when merging $3 into origin/$2 would change nothing, i.e. everything the
# branch carries is already in the base, however it landed (merge commit, squash
# or rebase). Commit ancestry can't answer that: squash and rebase merges rewrite
# the commits. Needs git 2.38+ (merge-tree --write-tree); any failure, a conflict
# included, counts as "not merged", the safe answer.
ew_content_merged() { # dir base ref
  local base_tree merged
  base_tree=$(git -C "$1" rev-parse --verify -q "refs/remotes/origin/$2^{tree}") || return 1
  merged=$(git -C "$1" merge-tree --write-tree "refs/remotes/origin/$2" "$3" 2>/dev/null) || return 1
  [[ "$(printf '%s\n' "$merged" | head -n 1)" == "$base_tree" ]]
}

# Where branch $2 started, as "<sha> <ref>": the oldest entry of its reflog,
# which reads "branch: Created from <ref>" (and survives the engine renaming a
# runtime-made branch). <ref> is "HEAD" when it was made from a checkout's HEAD.
# Prints nothing when that's unknown: the reflog is gone (git gc can expire it
# after about a month), or the branch was recreated from its own remote copy.
ew_branch_start() { # dir branch
  local start ref
  start=$(git -C "$1" reflog show --format='%H %gs' "refs/heads/$2" 2>/dev/null | tail -n 1 \
    | sed -n 's/^\([0-9a-f]\{40,\}\) branch: Created from \(.*\)$/\1 \2/p') || true
  [[ -n "$start" ]] || return 0
  ref=$(ew_short_branch "${start#* }")
  [[ "$ref" != "$2" ]] || return 0
  echo "$start"
}

# A branch name from a ref as the reflog records it: refs/heads/x, origin/x, ...
ew_short_branch() { # ref
  local ref="$1"
  ref="${ref#refs/heads/}"
  ref="${ref#refs/remotes/}"
  echo "${ref#origin/}"
}

# The branch work from $3 merges into, as "<base> <why>". In order: the base its
# last merged PR used; the branch it started from, when origin has it (a WordPress
# env starts from whatever its checkout has checked out, often a long-lived
# feature branch); else the repo's default branch.
ew_base_for() { # dir slug branch
  local merged start ref
  merged=$(gh pr list --repo "$2" --head "$3" --state merged --limit 1 \
    --json baseRefName --jq '.[0].baseRefName // empty') || return 1
  if [[ -n "$merged" ]]; then
    echo "$merged merged-pr"
    return 0
  fi
  start=$(ew_branch_start "$1" "$3")
  ref=$(ew_short_branch "${start#* }")
  if [[ -n "$start" && "$ref" != HEAD ]] \
    && git -C "$1" rev-parse --verify -q "refs/remotes/origin/$ref" >/dev/null; then
    echo "$ref started-from"
    return 0
  fi
  ref=$(ew_default_branch "$2") || return 1
  echo "$ref default"
}

# How many commits branch $2 adds that origin/$3 lacks: counted from $4, the commit
# the env started from, when that's known, so the env's own work counts even if
# another branch has it too (a stacked env, a backup branch). With no start record,
# only commits found on no other branch or remote count; the branch's own remote
# copy doesn't count as "elsewhere", since pushed work still needs its PR.
ew_own_commits() { # dir branch base [start-sha]
  local ref
  ref=$(ew_branch_ref "$1" "$2")
  [[ -n "$ref" ]] || { echo 0; return 0; }
  if [[ -n "${4:-}" ]]; then
    git -C "$1" rev-list --count "$ref" --not "refs/remotes/origin/$3" "$4"
  else
    git -C "$1" rev-list --count "$ref" --not "refs/remotes/origin/$3" \
      --exclude="$2" --branches --exclude="origin/$2" --remotes
  fi
}

# The ref to compare for branch $2 in $1: the local branch, else its remote copy.
# Prints nothing when neither exists.
ew_branch_ref() { # dir branch
  if git -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null; then
    echo "refs/heads/$2"
  elif git -C "$1" rev-parse --verify -q "refs/remotes/origin/$2" >/dev/null; then
    echo "refs/remotes/origin/$2"
  fi
}
