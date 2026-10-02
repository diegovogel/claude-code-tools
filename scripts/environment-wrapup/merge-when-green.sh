#!/usr/bin/env bash
#
# merge-when-green.sh — wait for a PR's CI to pass, merge it, delete its branch.
#
# Usage: merge-when-green.sh <owner/repo> <pr-number> [options]
#   --method merge|squash|rebase  how to merge (default: the repo's own habit, see pick_method)
#   --timeout <minutes>           give up waiting after this long (default 60)
#   --allow-no-checks             merge even though the repo normally runs CI and none appeared
#
# Doesn't use GitHub auto-merge: some repos can't turn it on, and a repo with no
# required checks would merge at once, before CI. Instead it polls the PR itself:
#
#   1. Waits until everything CI runs on the PR's head commit has finished and
#      passed: the check runs and statuses GitHub reports, and every GitHub
#      Actions workflow run. The runs matter twice over: a job waiting on another
#      job has no check run yet, and a workflow that fails before any job starts
#      (a broken workflow file, say) has no check run at all.
#   2. No checks at all: merges at once only when nothing suggests the repo runs
#      CI (no checks on its recent merged PRs or on this PR's earlier commits, no
#      workflow that runs on pull requests). Otherwise it waits a few minutes for
#      CI to start, then gives up with exit 4.
#   3. Updates a branch that is behind its base when branch rules require that,
#      then waits for the new run.
#   4. Merges exactly the commit that passed (--match-head-commit), then deletes
#      the remote branch unless it belongs to a fork, is the default branch, or is
#      the base of another open PR.
#
# A failed read from GitHub (the PR, its workflow runs, the merge settings) is
# retried on the next poll; only five in a row end the run. A failed branch update
# or merge is retried too (GitHub refuses a merge when the base moved a moment
# earlier), and a merge that went through despite an error counts as merged.
#
# Progress goes to stderr; the result is one JSON line on stdout:
#   {"repo","pr","url","method","merge_commit","branch","branch_deleted","branch_note"}
#
# Exit codes:
#   0  merged (or found already merged); see branch_deleted
#   2  a check failed (listed on stderr)
#   3  timed out waiting
#   4  the repo runs CI, but no checks appeared on this PR (rerun with --allow-no-checks to merge anyway)
#   5  not mergeable: closed, draft, conflicts, blocked by review or branch rules
#   6  usage or tool error
#
# Meant to run as a background Bash task; it can block for up to --timeout.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ew_need gh jq

POLL_SECONDS="${MWG_POLL_SECONDS:-15}"
NO_CHECKS_GRACE_SECONDS="${MWG_NO_CHECKS_GRACE_SECONDS:-180}"
MAX_BRANCH_UPDATES=3
MAX_READ_FAILURES=5
MAX_MERGE_ATTEMPTS=3

usage() { ew_die 6 "usage: $(basename "$0") <owner/repo> <pr-number> [--method merge|squash|rebase] [--timeout <minutes>] [--allow-no-checks]"; }

[[ $# -ge 2 ]] || usage
slug="$1" pr="$2"
shift 2
[[ "$slug" == */* && "$pr" =~ ^[0-9]+$ ]] || usage
method="" timeout_minutes=60 allow_no_checks=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --method)
      [[ $# -ge 2 && "$2" =~ ^(merge|squash|rebase)$ ]] || usage
      method="$2"; shift 2 ;;
    --timeout)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage
      timeout_minutes="$2"; shift 2 ;;
    --allow-no-checks) allow_no_checks=true; shift ;;
    *) usage ;;
  esac
done

say() { echo "merge-when-green $slug#$pr: $*" >&2; }

pr_view() {
  gh pr view "$pr" --repo "$slug" --json \
    number,url,state,isDraft,headRefOid,headRefName,baseRefName,isCrossRepository,mergeable,mergeStateStatus,statusCheckRollup,mergeCommit
}

# The PR's checks as [{name, state: ok|pending|failed, url}]. The rollup keeps
# superseded check runs (one a re-run replaced, or one cancelled by a newer run),
# so only the newest run of each check counts; a run not started yet is newest.
classify_checks() {
  jq -c '
    (.statusCheckRollup // []) as $all
    | [$all[] | select(.__typename == "CheckRun")]
      | group_by([.workflowName // "", .name])
      | map(sort_by(.startedAt // "9999") | last)
    | . + [$all[] | select(.__typename != "CheckRun")]
    | map(
        if .__typename == "CheckRun" then
          {name: (if (.workflowName // "") != "" then .workflowName + " / " + .name else .name end),
           url: (.detailsUrl // ""),
           state: (if .status != "COMPLETED" then "pending"
                   elif ((.conclusion // "") | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then "ok"
                   else "failed" end)}
        else
          {name: .context, url: (.targetUrl // ""),
           state: (if (.state | IN("PENDING", "EXPECTED")) then "pending"
                   elif .state == "SUCCESS" then "ok" else "failed" end)}
        end)'
}

# The GitHub Actions workflow runs for the commit as [{name, state, url}], like
# classify_checks: the newest attempt of each workflow and event, minus a cancelled
# run that a newer run of the same workflow replaced (a concurrency group shared by
# push and pull_request cancels one of the two). Prints "unreadable" when the read
# failed in a way that may pass. gh prints an error's JSON body on stdout, and a
# repo without Actions, or a token without access, answers 404 or 403 every time,
# which reads as no runs.
actions_runs() { # sha
  local out
  if out=$(gh api "repos/$slug/actions/runs?head_sha=$1&per_page=100" 2>/dev/null) \
    && jq -e '.workflow_runs | type == "array"' <<<"$out" >/dev/null 2>&1; then
    jq -c '
      .workflow_runs
      | (group_by(.workflow_id) | map({key: (.[0].workflow_id | tostring), value: (map(.run_number) | max)})
         | from_entries) as $newest
      | group_by([.workflow_id, .event])
      | map(sort_by(.run_number, .run_attempt) | last)
      | map(select(.conclusion != "cancelled" or .run_number == $newest[.workflow_id | tostring]))
      | map({name: (.name + " (workflow)"), url: (.html_url // ""),
             state: (if .status != "completed" then "pending"
                     elif ((.conclusion // "") | IN("success", "neutral", "skipped")) then "ok"
                     else "failed" end)})' <<<"$out"
  elif jq -e '((.status // "") | tostring | test("^40[34]$"))
      or ((.message // "") | test("Not Found|Resource not accessible"))' <<<"$out" >/dev/null 2>&1; then
    echo '[]'
  else
    echo unreadable
  fi
}

seen_checks=false
ci_expected_cache=""
# Whether CI should be expected when this head has no checks. Any sign of CI counts,
# and a lookup that fails counts as a sign: when unsure, wait rather than merge.
ci_expected() { # base
  [[ "$seen_checks" == true ]] && return 0
  if [[ -z "$ci_expected_cache" ]]; then
    ci_expected_cache=no
    local history paths p content
    if ! history=$(gh pr list --repo "$slug" --state merged --base "$1" --limit 5 \
      --json statusCheckRollup --jq '[.[] | (.statusCheckRollup | length)]' 2>/dev/null) \
      || ! jq -e 'type == "array"' <<<"$history" >/dev/null 2>&1; then
      ci_expected_cache=yes
    elif jq -e 'any(. > 0)' <<<"$history" >/dev/null; then
      ci_expected_cache=yes
    elif ! paths=$(gh api "repos/$slug/actions/workflows?per_page=100" --jq \
      '.workflows[] | select(.state == "active" and (.path | startswith(".github/workflows/"))) | .path' \
      2>/dev/null); then
      ci_expected_cache=yes
    else
      # A workflow file that runs on pull requests. GitHub's own dynamic workflows
      # (Dependabot, CodeQL default setup) are skipped: they have no file to read.
      for p in $paths; do
        if ! content=$(gh api "repos/$slug/contents/$p?ref=$1" --jq '.content | gsub("\n"; "") | @base64d' 2>/dev/null) \
          || grep -q 'pull_request' <<<"$content"; then
          ci_expected_cache=yes
          break
        fi
      done
    fi
  fi
  [[ "$ci_expected_cache" == yes ]]
}

# The repo's merge habit: the only method it allows, else the method its last
# merged PR used (two parents means a merge commit; one means squash or rebase,
# taken as squash when allowed), else a merge commit, GitHub's default.
pick_method() { # base
  local allowed last parents m
  allowed=$(gh api "repos/$slug" --jq \
    '[if .allow_merge_commit then "merge" else empty end,
      if .allow_squash_merge then "squash" else empty end,
      if .allow_rebase_merge then "rebase" else empty end] | join(" ")') || return 1
  case "$allowed" in
    merge | squash | rebase) echo "$allowed"; return ;;
    "") echo none; return ;;
  esac
  last=$(gh pr list --repo "$slug" --state merged --base "$1" --limit 1 \
    --json mergeCommit --jq '.[0].mergeCommit.oid // empty' 2>/dev/null) || last=""
  if [[ -n "$last" ]]; then
    parents=$(gh api "repos/$slug/commits/$last" --jq '.parents | length' 2>/dev/null) || parents=""
    if [[ "$parents" == 2 && " $allowed " == *" merge "* ]]; then echo merge; return; fi
    if [[ "$parents" == 1 && " $allowed " == *" squash "* ]]; then echo squash; return; fi
    if [[ "$parents" == 1 && " $allowed " == *" rebase "* ]]; then echo rebase; return; fi
  fi
  for m in merge squash rebase; do
    [[ " $allowed " == *" $m "* ]] && { echo "$m"; return; }
  done
}

# Delete the PR's remote branch when that's safe. Prints a one-line note.
delete_branch() { # head-branch is-cross-repo
  local head="$1" is_fork="$2" default dependents out
  if [[ "$is_fork" == true ]]; then echo "kept: it belongs to a fork"; return 1; fi
  default=$(ew_default_branch "$slug") || { echo "kept: couldn't read the default branch"; return 1; }
  if [[ "$head" == "$default" ]]; then echo "kept: it is the default branch"; return 1; fi
  dependents=$(gh pr list --repo "$slug" --base "$head" --state open --json number --jq 'length') \
    || { echo "kept: couldn't check for PRs based on it"; return 1; }
  if ((dependents > 0)); then echo "kept: $dependents open PR(s) target it"; return 1; fi
  if gh api -X DELETE "repos/$slug/git/refs/heads/$head" >/dev/null 2>&1; then
    echo "deleted"; return 0
  fi
  # The repo may delete merged branches itself. Only a 404 proves it's gone.
  if out=$(gh api "repos/$slug/git/ref/heads/$head" 2>&1); then
    echo "kept: the delete request failed"; return 1
  elif grep -q 'HTTP 404' <<<"$out"; then
    echo "already deleted"; return 0
  fi
  echo "kept: the delete request failed, and the branch's state couldn't be read"; return 1
}

finish() { # method merge-commit head is-cross-repo url
  local note deleted=false
  if note=$(delete_branch "$3" "$4"); then deleted=true; fi
  say "branch $3: $note"
  jq -nc --arg repo "$slug" --argjson pr "$pr" --arg url "$5" --arg method "$1" --arg commit "$2" \
    --arg branch "$3" --argjson deleted "$deleted" --arg note "$note" \
    '{repo: $repo, pr: $pr, url: $url, method: $method, merge_commit: $commit, branch: $branch,
      branch_deleted: $deleted, branch_note: $note}'
  exit 0
}

start=$(date +%s)
deadline=$((start + timeout_minutes * 60))
updates=0 blocked_polls=0 read_failures=0 merge_attempts=0 merge_exhausted=false
last_report="" last_sha="" green_seen="" merge_wait_start=""
grace_start=$start
FS=$'\x1f' # field separator for the PR summary; unlike a tab, never collapsed by read

# A read from GitHub failed: retry next poll, up to MAX_READ_FAILURES in a row.
read_failed() { # what
  read_failures=$((read_failures + 1))
  ((read_failures < MAX_READ_FAILURES)) || ew_die 6 "can't read $1 from GitHub ($read_failures tries in a row)"
  report="couldn't read $1; retrying"
  green_seen=""
}

# One poll. Sets $report; exits the script once there's an outcome.
poll() {
  local view state draft sha head base fork url mergeable merge_state merged_oid
  local checks runs failed pending total ready=false picked

  if ! view=$(pr_view 2>/dev/null) || ! jq -e '.state' <<<"$view" >/dev/null 2>&1; then
    read_failed "the PR"
    return
  fi
  IFS="$FS" read -r state draft sha head base fork url mergeable merge_state merged_oid < <(
    jq -r --arg fs "$FS" '[.state, .isDraft, .headRefOid, .headRefName, .baseRefName,
      .isCrossRepository, .url, .mergeable, .mergeStateStatus, (.mergeCommit.oid // "")]
      | map(tostring) | join($fs)' <<<"$view")

  case "$state" in
    MERGED)
      say "merged"
      finish "$method" "$merged_oid" "$head" "$fork" "$url" ;;
    CLOSED) ew_die 5 "$url is closed without being merged" ;;
  esac
  # The last merge attempt failed and this read shows it didn't go through.
  [[ "$merge_exhausted" == false ]] || ew_die 5 "gh pr merge refused $url $merge_attempts times (see above)"
  [[ "$draft" != true ]] || ew_die 5 "$url is a draft; mark it ready for review first"

  # A new head commit (a push, or our own branch update) gets its own wait for
  # checks to appear.
  if [[ "$sha" != "$last_sha" ]]; then
    last_sha="$sha"
    grace_start=$(date +%s)
  fi

  runs=$(actions_runs "$sha")
  if [[ "$runs" == unreadable ]]; then
    read_failed "the workflow runs"
    return
  fi
  read_failures=0
  checks=$(classify_checks <<<"$view")
  checks=$(jq -c --argjson runs "$runs" '. + $runs' <<<"$checks")
  failed=$(jq -r '.[] | select(.state == "failed") | "  \(.name)  \(.url)"' <<<"$checks")
  if [[ -n "$failed" ]]; then
    echo "failed checks on $url (head ${sha:0:7}):" >&2
    echo "$failed" >&2
    exit 2
  fi
  pending=$(jq -c '[.[] | select(.state == "pending") | .name] | unique' <<<"$checks")
  total=$(jq 'length' <<<"$checks")
  ((total == 0)) || seen_checks=true

  if [[ "$pending" != "[]" ]]; then
    report="waiting on $(jq -r 'join(", ")' <<<"$pending")"
    green_seen=""
  elif ((total > 0)); then
    # Two green polls in a row: workflows triggered by one push can register a
    # few seconds apart.
    if [[ "$green_seen" == "$sha:$total" ]]; then
      ready=true
    else
      green_seen="$sha:$total"
      report="all $total check(s) passed; confirming no more are starting"
    fi
  elif [[ "$allow_no_checks" == true ]] || ! ci_expected "$base"; then
    ready=true
  elif (($(date +%s) - grace_start >= NO_CHECKS_GRACE_SECONDS)); then
    ew_die 4 "$slug normally runs CI, but no checks appeared on $url within $((NO_CHECKS_GRACE_SECONDS / 60)) min"
  else
    report="no checks yet; waiting for CI to start"
  fi
  [[ "$ready" == true ]] || return 0

  [[ "$merge_state" == BLOCKED ]] && blocked_polls=$((blocked_polls + 1)) || blocked_polls=0
  case "$mergeable/$merge_state" in
    CONFLICTING/* | */DIRTY) ew_die 5 "$url has merge conflicts with $base" ;;
    */BEHIND)
      ((updates < MAX_BRANCH_UPDATES)) || ew_die 5 "$url is still behind $base after $updates update attempts"
      updates=$((updates + 1))
      say "branch is behind $base and must be up to date; updating it"
      if gh api -X PUT "repos/$slug/pulls/$pr/update-branch" -f expected_head_sha="$sha" >/dev/null; then
        report="branch updated; waiting for its checks"
      else
        report="couldn't update the branch from $base; retrying"
      fi ;;
    */BLOCKED)
      # GitHub can report BLOCKED for a moment after the last required check
      # passes, so only a state that persists counts.
      ((blocked_polls < 3)) || ew_die 5 "$url is blocked by branch rules (a required review or check); see the PR"
      report="checks passed, but GitHub reports the PR as blocked; rechecking" ;;
    MERGEABLE/CLEAN | MERGEABLE/HAS_HOOKS | MERGEABLE/UNSTABLE)
      if [[ -n "$merge_wait_start" ]]; then
        # Already requested: GitHub can show the PR open for a moment after.
        report="merge requested; waiting for GitHub to report it merged"
        return 0
      fi
      if [[ -z "$method" ]]; then
        picked=$(pick_method "$base") || { read_failed "the repo's merge settings"; return; }
        [[ "$picked" != none ]] || ew_die 5 "$slug allows no merge method"
        method="$picked"
      fi
      merge_attempts=$((merge_attempts + 1))
      say "checks passed; merging ${sha:0:7} with --$method"
      if gh pr merge "$pr" --repo "$slug" "--$method" --match-head-commit "$sha" >&2; then
        report="merge requested; waiting for GitHub to report it merged"
        merge_wait_start=$(date +%s)
      else
        # The next poll sees MERGED if it went through anyway; otherwise retry.
        ((merge_attempts < MAX_MERGE_ATTEMPTS)) || merge_exhausted=true
        report="gh pr merge failed; checking the PR again"
      fi ;;
    *) report="checks passed; waiting for GitHub to work out mergeability ($mergeable/$merge_state)" ;;
  esac
}

while :; do
  report=""
  poll
  # A merge GitHub accepted but hasn't reported as done (a merge queue, say).
  if [[ -n "$merge_wait_start" ]] && (($(date +%s) - merge_wait_start > 60)); then
    ew_die 5 "merge requested, but #$pr isn't merged yet (a merge queue?)"
  fi
  if [[ -n "$report" && "$report" != "$last_report" ]]; then
    say "$report"
    last_report="$report"
  fi
  if (($(date +%s) >= deadline)); then
    ew_die 3 "timed out after $timeout_minutes min; last state: ${last_report:-unknown}"
  fi
  sleep "$POLL_SECONDS"
done
