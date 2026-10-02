#!/usr/bin/env bash
#
# Tests for the environment-wrapup scripts. No network: gh is the fake in
# tests/bin, git runs for real in throwaway repos.
#
#   tests/run-tests.sh            # all
#   tests/run-tests.sh <pattern>  # only tests whose name contains <pattern>

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPTS=$(dirname "$HERE")
export PATH="$HERE/bin:$PATH"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
export MWG_POLL_SECONDS=0 MWG_NO_CHECKS_GRACE_SECONDS=0
# Every script run is cut off after this long (exit 124), so a broken wait loop
# fails its test instead of polling for an hour.
LIMIT="$(command -v timeout || command -v gtimeout) 15"

FILTER="${1:-}"
pass=0 fail=0 failures=""

# ---------------------------------------------------------------------------
# Harness

setup() {
  T=$(cd "$(mktemp -d)" && pwd -P)
  export GH_STATE="$T/gh"
  mkdir -p "$GH_STATE"
  : >"$GH_STATE/calls"
}

run() { # name function
  [[ -z "$FILTER" || "$1" == *"$FILTER"* ]] || return 0
  setup
  local err="$T/test.err" rc
  # Not inside `if`: bash ignores set -e for anything run as an if condition,
  # which would let every check but a test's last one fail silently.
  ( set -e; "$2" ) >"$T/test.out" 2>"$err"
  rc=$?
  if ((rc == 0)); then
    pass=$((pass + 1)); echo "ok   $1"
  else
    fail=$((fail + 1)); failures="$failures $1"; echo "FAIL $1"
    sed 's/^/     /' "$err" | tail -n 25
  fi
  rm -rf "$T"
}

check() { # description command...
  local d="$1"; shift
  "$@" || { echo "check failed: $d" >&2; return 1; }
}

# Run a script, capturing stdout, stderr and the exit code.
capture() { # script args...
  local s="$1"; shift
  set +e
  OUT=$($LIMIT "$SCRIPTS/$s" "$@" 2>"$T/stderr")
  CODE=$?
  set -e
  ERR=$(cat "$T/stderr")
}

expect_code() { [[ "$CODE" == "$1" ]] || { echo "expected exit $1, got $CODE; stderr: $ERR; stdout: $OUT" >&2; return 1; }; }
called() { grep -q -- "$1" "$GH_STATE/calls" || { echo "expected a gh call matching: $1" >&2; cat "$GH_STATE/calls" >&2; return 1; }; }
no_branch() { ! git -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null; }
not_called() { ! grep -q -- "$1" "$GH_STATE/calls" || { echo "unexpected gh call matching: $1" >&2; return 1; }; }

# A PR view as gh prints it. Checks are [name, status, conclusion] triples or
# raw JSON; "none" means no checks.
view() { # file state merge_state checks-json [mergeable] [sha] [draft] [cross]
  jq -n --arg state "$2" --arg ms "$3" --argjson checks "$4" --arg m "${5:-MERGEABLE}" \
    --arg sha "${6:-aaaaaaaa}" --argjson draft "${7:-false}" --argjson cross "${8:-false}" \
    '{number: 7, url: "https://github.com/o/r/pull/7", state: $state, isDraft: $draft,
      headRefOid: $sha, headRefName: "worktree-x", baseRefName: "main", isCrossRepository: $cross,
      mergeable: $m, mergeStateStatus: $ms, statusCheckRollup: $checks, mergeCommit: null}' \
    >"$GH_STATE/$1"
  jq '.state = "MERGED" | .mergeCommit = {oid: "mmmmmmmm"}' "$GH_STATE/$1" >"$GH_STATE/view.merged.json"
}
# An actions/runs answer holding one workflow run.
wf_run() { # name status conclusion [run_number] [workflow_id]
  jq -n --arg n "$1" --arg s "$2" --argjson c "$( [[ "$3" == null ]] && echo null || echo "\"$3\"" )" \
    --argjson num "${4:-1}" --argjson id "${5:-1}" \
    '{workflow_runs: [{name: $n, status: $s, conclusion: $c, run_number: $num, run_attempt: 1,
      workflow_id: $id, event: "pull_request", html_url: "https://github.com/o/r/actions/runs/9"}]}'
}
run_ok() { echo "{\"__typename\":\"CheckRun\",\"name\":\"$1\",\"workflowName\":\"ci\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\",\"detailsUrl\":\"u\"}"; }
run_pending() { echo "{\"__typename\":\"CheckRun\",\"name\":\"$1\",\"workflowName\":\"ci\",\"status\":\"IN_PROGRESS\",\"conclusion\":null,\"detailsUrl\":\"u\"}"; }
run_failed() { echo "{\"__typename\":\"CheckRun\",\"name\":\"$1\",\"workflowName\":\"ci\",\"status\":\"COMPLETED\",\"conclusion\":\"FAILURE\",\"detailsUrl\":\"u\"}"; }

# ---------------------------------------------------------------------------
# merge-when-green.sh

t_merges_after_green_is_confirmed() {
  view view.1.json OPEN UNSTABLE "[$(run_pending lint), $(run_ok tests)]"
  view view.2.json OPEN CLEAN "[$(run_ok lint), $(run_ok tests)]"
  capture merge-when-green.sh o/r 7
  expect_code 0
  check "merge used the repo's method and pinned the head" called "pr merge 7 --repo o/r --merge --match-head-commit aaaaaaaa"
  # pending, green, confirmed green, then the post-merge read
  check "green was confirmed on a second poll before merging" [ "$(cat "$GH_STATE/view-count")" -ge 4 ]
  check "reports the deleted branch" jq -e '.branch_deleted == true and .merge_commit == "mmmmmmmm"' <<<"$OUT"
  called "DELETE repos/o/r/git/refs/heads/worktree-x"
}

t_failed_check_stops_without_merging() {
  view view.1.json OPEN UNSTABLE "[$(run_failed tests), $(run_pending lint)]"
  capture merge-when-green.sh o/r 7
  expect_code 2
  not_called "pr merge"
  check "names the failed check" grep -q 'ci / tests' <<<"$ERR"
}

t_failed_status_context_counts() {
  view view.1.json OPEN UNSTABLE '[{"__typename":"StatusContext","context":"vercel","state":"ERROR","targetUrl":"u"}]'
  capture merge-when-green.sh o/r 7
  expect_code 2
  not_called "pr merge"
}

t_waits_for_a_running_actions_workflow() {
  view view.1.json OPEN CLEAN "[$(run_ok lint)]"
  wf_run deploy-preview in_progress null >"$GH_STATE/runs.1.json"
  wf_run deploy-preview in_progress null >"$GH_STATE/runs.2.json"
  wf_run deploy-preview completed success >"$GH_STATE/runs.3.json"
  capture merge-when-green.sh o/r 7
  expect_code 0
  check "waited on the run" grep -q 'waiting on deploy-preview' <<<"$ERR"
  check "polled past the running workflow" [ "$(cat "$GH_STATE/view-count")" -ge 5 ]
}

t_merges_at_once_when_the_repo_has_no_ci() {
  view view.1.json OPEN CLEAN '[]'
  echo '[{"statusCheckRollup":[]},{"statusCheckRollup":[]}]' >"$GH_STATE/merged-history.json"
  capture merge-when-green.sh o/r 7
  expect_code 0
  called "pr merge 7"
}

t_waits_then_gives_up_when_ci_never_starts() {
  view view.1.json OPEN CLEAN '[]'
  echo "[{\"statusCheckRollup\":[$(run_ok tests)]}]" >"$GH_STATE/merged-history.json"
  capture merge-when-green.sh o/r 7
  expect_code 4
  not_called "pr merge"
}

t_allow_no_checks_overrides_the_ci_wait() {
  view view.1.json OPEN CLEAN '[]'
  echo "[{\"statusCheckRollup\":[$(run_ok tests)]}]" >"$GH_STATE/merged-history.json"
  capture merge-when-green.sh o/r 7 --allow-no-checks
  expect_code 0
  called "pr merge 7"
}

t_first_pr_with_a_pull_request_workflow_waits_for_ci() {
  view view.1.json OPEN CLEAN '[]'
  echo '{"workflows":[{"state":"active","path":"dynamic/dependabot/dependabot-updates"},{"state":"active","path":".github/workflows/ci.yml"}]}' >"$GH_STATE/workflows.json"
  jq -n --arg c "$(printf 'on:\n  pull_request:\n' | base64)" '{content: $c}' >"$GH_STATE/contents.json"
  capture merge-when-green.sh o/r 7
  expect_code 4
}

t_first_pr_with_only_dynamic_workflows_merges() {
  view view.1.json OPEN CLEAN '[]'
  echo '{"workflows":[{"state":"active","path":"dynamic/dependabot/dependabot-updates"}]}' >"$GH_STATE/workflows.json"
  capture merge-when-green.sh o/r 7
  expect_code 0
  called "pr merge 7"
}

t_conflicts_stop_without_merging() {
  view view.1.json OPEN DIRTY "[$(run_ok tests)]" CONFLICTING
  capture merge-when-green.sh o/r 7
  expect_code 5
  not_called "pr merge"
}

t_behind_branch_is_updated_then_merged() {
  view view.1.json OPEN BEHIND "[$(run_ok tests)]"
  view view.2.json OPEN BEHIND "[$(run_ok tests)]"
  view view.3.json OPEN UNSTABLE "[$(run_pending tests)]" MERGEABLE bbbbbbbb
  view view.4.json OPEN CLEAN "[$(run_ok tests)]" MERGEABLE bbbbbbbb
  capture merge-when-green.sh o/r 7
  expect_code 0
  called "update-branch"
  called "pr merge 7 --repo o/r --merge --match-head-commit bbbbbbbb"
}

t_ci_wait_restarts_for_the_updated_branch() {
  # Real time: the first head's checks take longer than the no-checks grace, and
  # the updated head must still get its own grace to start CI.
  export MWG_POLL_SECONDS=1 MWG_NO_CHECKS_GRACE_SECONDS=2
  echo "[{\"statusCheckRollup\":[$(run_ok tests)]}]" >"$GH_STATE/merged-history.json"
  view view.1.json OPEN UNSTABLE "[$(run_pending tests)]"
  view view.4.json OPEN BEHIND "[$(run_ok tests)]"
  view view.6.json OPEN UNSTABLE '[]' MERGEABLE bbbbbbbb
  view view.7.json OPEN UNSTABLE "[$(run_pending tests)]" MERGEABLE bbbbbbbb
  view view.8.json OPEN CLEAN "[$(run_ok tests)]" MERGEABLE bbbbbbbb
  capture merge-when-green.sh o/r 7
  expect_code 0
  called "pr merge 7 --repo o/r --merge --match-head-commit bbbbbbbb"
}

t_brief_blocked_state_is_waited_out() {
  view view.1.json OPEN BLOCKED "[$(run_ok tests)]"
  view view.3.json OPEN CLEAN "[$(run_ok tests)]"
  capture merge-when-green.sh o/r 7
  expect_code 0
}

t_lasting_blocked_state_stops() {
  view view.1.json OPEN BLOCKED "[$(run_ok tests)]"
  capture merge-when-green.sh o/r 7
  expect_code 5
  not_called "pr merge"
}

t_draft_stops() {
  # Checks still running: a draft is refused up front, not after CI.
  view view.1.json OPEN DRAFT "[$(run_pending tests)]" MERGEABLE aaaaaaaa true
  capture merge-when-green.sh o/r 7
  expect_code 5
  not_called "pr merge"
}

t_already_merged_only_cleans_up() {
  view view.1.json MERGED UNKNOWN "[$(run_ok tests)]"
  jq '.mergeCommit = {oid: "mmmmmmmm"}' "$GH_STATE/view.1.json" >"$GH_STATE/x" && mv "$GH_STATE/x" "$GH_STATE/view.1.json"
  echo 1 >"$GH_STATE/delete-rc"
  capture merge-when-green.sh o/r 7
  expect_code 0
  not_called "pr merge"
  check "a branch GitHub already deleted counts as deleted" jq -e '.branch_deleted == true and .branch_note == "already deleted"' <<<"$OUT"
}

t_branch_another_pr_targets_is_kept() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  echo '[{"number":8}]' >"$GH_STATE/dependents.json"
  capture merge-when-green.sh o/r 7
  expect_code 0
  not_called "DELETE"
  check "says why" jq -e '.branch_deleted == false and (.branch_note | test("target it"))' <<<"$OUT"
}

t_fork_branch_is_kept() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]" MERGEABLE aaaaaaaa false true
  capture merge-when-green.sh o/r 7
  expect_code 0
  not_called "DELETE"
}

t_method_follows_the_last_merge() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  echo '{"allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":true}' >"$GH_STATE/repo.json"
  echo '[{"mergeCommit":{"oid":"cccc"}}]' >"$GH_STATE/merged-last.json"
  echo '{"parents":[{}]}' >"$GH_STATE/commit.json"
  capture merge-when-green.sh o/r 7
  expect_code 0
  called "pr merge 7 --repo o/r --squash"
}

t_refused_merge_stops() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  echo 1 >"$GH_STATE/merge-rc"
  capture merge-when-green.sh o/r 7
  expect_code 5
}

t_times_out() {
  view view.1.json OPEN UNSTABLE "[$(run_pending tests)]"
  capture merge-when-green.sh o/r 7 --timeout 0
  expect_code 3
  not_called "pr merge"
}

t_workflow_that_never_started_blocks_the_merge() {
  # A run that fails before any job (startup_failure) has no check run, so only
  # the runs API shows it.
  view view.1.json OPEN CLEAN "[$(run_ok lint)]"
  wf_run tests completed startup_failure >"$GH_STATE/runs.1.json"
  capture merge-when-green.sh o/r 7
  expect_code 2
  not_called "pr merge"
  check "names the workflow" grep -q 'tests (workflow)' <<<"$ERR"
}

t_a_rerun_replaces_a_failed_workflow_run() {
  view view.1.json OPEN CLEAN "[$(run_ok lint)]"
  jq -s '{workflow_runs: (map(.workflow_runs) | add)}' \
    <(wf_run tests completed failure 3) <(wf_run tests completed success 4) >"$GH_STATE/runs.1.json"
  capture merge-when-green.sh o/r 7
  expect_code 0
}

t_superseded_cancelled_check_run_is_ignored() {
  local cancelled='{"__typename":"CheckRun","name":"tests","workflowName":"ci","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-10-02T10:00:00Z","detailsUrl":"u"}'
  local passed='{"__typename":"CheckRun","name":"tests","workflowName":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-02T10:05:00Z","detailsUrl":"u"}'
  view view.1.json OPEN CLEAN "[$cancelled, $passed]"
  capture merge-when-green.sh o/r 7
  expect_code 0
}

t_an_actions_error_reads_as_no_runs() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  touch "$GH_STATE/runs-error"
  capture merge-when-green.sh o/r 7
  expect_code 0
  called "pr merge 7"
}

t_a_failed_pr_read_is_retried() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  touch "$GH_STATE/view-fail.2" "$GH_STATE/view-fail.3"
  capture merge-when-green.sh o/r 7
  expect_code 0
  called "pr merge 7"
}

t_five_failed_pr_reads_in_a_row_stop() {
  view view.1.json OPEN UNSTABLE "[$(run_pending tests)]"
  for n in 2 3 4 5 6; do touch "$GH_STATE/view-fail.$n"; done
  capture merge-when-green.sh o/r 7
  expect_code 6
  not_called "pr merge"
}

t_a_refused_merge_is_retried() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  echo 1 >"$GH_STATE/merge-rc.1"
  capture merge-when-green.sh o/r 7
  expect_code 0
  check "two merge attempts" [ "$(grep -c 'pr merge' "$GH_STATE/calls")" -eq 2 ]
}

t_a_merge_that_errored_but_went_through_counts() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  echo 1 >"$GH_STATE/merge-rc"
  touch "$GH_STATE/merge-merges-anyway"
  capture merge-when-green.sh o/r 7
  expect_code 0
  check "one merge attempt" [ "$(grep -c 'pr merge' "$GH_STATE/calls")" -eq 1 ]
  check "reports the merge" jq -e '.merge_commit == "mmmmmmmm"' <<<"$OUT"
}

t_merge_is_requested_once_while_github_catches_up() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  echo 2 >"$GH_STATE/merged-delay"
  capture merge-when-green.sh o/r 7
  expect_code 0
  check "one merge request" [ "$(grep -c 'pr merge' "$GH_STATE/calls")" -eq 1 ]
}

t_pr_workflow_file_means_ci_despite_history() {
  # Recent merged PRs had no checks (CI was added since), but a workflow runs on PRs.
  view view.1.json OPEN CLEAN '[]'
  echo '[{"statusCheckRollup":[]}]' >"$GH_STATE/merged-history.json"
  echo '{"workflows":[{"state":"active","path":".github/workflows/ci.yml"}]}' >"$GH_STATE/workflows.json"
  jq -n --arg c "$(printf 'on:\n  pull_request:\n' | base64)" '{content: $c}' >"$GH_STATE/contents.json"
  capture merge-when-green.sh o/r 7
  expect_code 4
  not_called "pr merge"
}

t_failed_ci_lookup_counts_as_ci() {
  view view.1.json OPEN CLEAN '[]'
  echo 1 >"$GH_STATE/merged-history-rc"
  capture merge-when-green.sh o/r 7
  expect_code 4
  not_called "pr merge"
}

t_checks_on_an_earlier_head_mean_ci_for_the_next() {
  # No history and no workflow file to go on, but the first head had checks: the
  # updated head must wait for its own instead of merging before CI registers.
  export MWG_POLL_SECONDS=1 MWG_NO_CHECKS_GRACE_SECONDS=5
  view view.1.json OPEN BEHIND "[$(run_ok tests)]"
  view view.3.json OPEN CLEAN '[]' MERGEABLE bbbbbbbb
  view view.5.json OPEN CLEAN "[$(run_ok tests)]" MERGEABLE bbbbbbbb
  capture merge-when-green.sh o/r 7
  expect_code 0
  check "waited for the new head's checks" [ "$(cat "$GH_STATE/view-count")" -ge 6 ]
}

t_branch_whose_state_cant_be_read_is_reported_kept() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  echo 1 >"$GH_STATE/delete-rc"
  echo error >"$GH_STATE/ref-state"
  capture merge-when-green.sh o/r 7
  expect_code 0
  check "not claimed as deleted" jq -e '.branch_deleted == false' <<<"$OUT"
}

t_cancelled_run_replaced_by_another_event_is_ignored() {
  # push and pull_request share a concurrency group, so one cancels the other.
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  jq -s '{workflow_runs: (map(.workflow_runs) | add)}' \
    <(wf_run ci completed cancelled 5 | jq '.workflow_runs[0].event = "push"') \
    <(wf_run ci completed success 6) >"$GH_STATE/runs.1.json"
  capture merge-when-green.sh o/r 7
  expect_code 0
}

t_failed_run_of_another_event_still_fails() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  jq -s '{workflow_runs: (map(.workflow_runs) | add)}' \
    <(wf_run ci completed failure 5 | jq '.workflow_runs[0].event = "push"') \
    <(wf_run ci completed success 6) >"$GH_STATE/runs.1.json"
  capture merge-when-green.sh o/r 7
  expect_code 2
  not_called "pr merge"
}

t_unreadable_runs_never_confirm_green() {
  # Green, then the runs read fails, then a run is seen going, then the read fails
  # again: none of that adds up to two green polls in a row.
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  touch "$GH_STATE/runs-fail.2" "$GH_STATE/runs-fail.4"
  wf_run deploy in_progress null >"$GH_STATE/runs.3.json"
  wf_run deploy completed failure >"$GH_STATE/runs.5.json"
  capture merge-when-green.sh o/r 7
  expect_code 2
  not_called "pr merge"
}

t_five_unreadable_run_reads_stop() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  for n in 1 2 3 4 5; do touch "$GH_STATE/runs-fail.$n"; done
  capture merge-when-green.sh o/r 7
  expect_code 6
  not_called "pr merge"
}

t_merge_settings_read_is_retried() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  echo '{"allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":false}' >"$GH_STATE/repo.json"
  touch "$GH_STATE/repo-fail.1"
  capture merge-when-green.sh o/r 7
  expect_code 0
  called "pr merge 7 --repo o/r --merge"
}

t_failed_branch_update_is_retried() {
  view view.1.json OPEN BEHIND "[$(run_ok tests)]"
  view view.4.json OPEN CLEAN "[$(run_ok tests)]" MERGEABLE bbbbbbbb
  touch "$GH_STATE/update-fail.1"
  capture merge-when-green.sh o/r 7
  expect_code 0
  check "updated on the second try" [ "$(cat "$GH_STATE/update-count")" -eq 2 ]
}

t_unreadable_workflow_file_counts_as_ci() {
  view view.1.json OPEN CLEAN '[]'
  echo '{"workflows":[{"state":"active","path":".github/workflows/ci.yml"}]}' >"$GH_STATE/workflows.json"
  echo 1 >"$GH_STATE/contents-rc"
  capture merge-when-green.sh o/r 7
  expect_code 4
  not_called "pr merge"
}

t_last_merge_attempt_that_went_through_counts() {
  view view.1.json OPEN CLEAN "[$(run_ok tests)]"
  echo 1 >"$GH_STATE/merge-rc"
  touch "$GH_STATE/merge-merges-anyway.3"
  capture merge-when-green.sh o/r 7
  expect_code 0
  check "reports the merge" jq -e '.merge_commit == "mmmmmmmm"' <<<"$OUT"
}

t_rejects_bad_arguments() {
  capture merge-when-green.sh o/r seven
  expect_code 6
  capture merge-when-green.sh o/r 7 --method fast-forward
  expect_code 6
}

# ---------------------------------------------------------------------------
# Git fixtures for env-status.sh and teardown.sh

# origin (bare) + main checkout + an env worktree on worktree-<name> with one
# commit that isn't on origin yet.
make_env() { # name [flavor-shim]
  git init -q --bare -b main "$T/origin.git"
  git clone -q "$T/origin.git" "$T/main" 2>/dev/null
  echo base >"$T/main/file.txt"
  git -C "$T/main" add file.txt
  git -C "$T/main" commit -q -m base
  git -C "$T/main" push -q origin main
  git -C "$T/main" remote set-head origin main
  mkdir -p "$T/main/.claude/worktrees"
  git -C "$T/main" worktree add -q -b "worktree-$1" "$T/main/.claude/worktrees/$1"
  ENV="$T/main/.claude/worktrees/$1"
  echo change >>"$ENV/file.txt"
  git -C "$ENV" commit -q -am change
}

# Merge the env branch on "GitHub" (origin), the way the PR would land.
land() { # name merge|squash
  local c="$T/landing"
  git -C "$ENV" push -q origin "worktree-$1"
  git clone -q "$T/origin.git" "$c" 2>/dev/null
  if [[ "$2" == squash ]]; then
    git -C "$c" merge -q --squash "origin/worktree-$1" >/dev/null
    git -C "$c" commit -q -m "squashed"
  else
    git -C "$c" merge -q --no-ff -m merged "origin/worktree-$1"
  fi
  git -C "$c" push -q origin main
  git -C "$c" push -q origin --delete "worktree-$1"
  rm -rf "$c"
}

# Merge the env branch on origin with a merge commit, leaving the remote branch.
land_keep_branch() { # name
  local c="$T/landing"
  git clone -q "$T/origin.git" "$c" 2>/dev/null
  git -C "$c" merge -q --no-ff -m merged "origin/worktree-$1"
  git -C "$c" push -q origin main
  rm -rf "$c"
}

# Like make_env, but the env branches from a person's feature branch (pushed,
# not merged into main), the way a WordPress env branches from its checkout.
make_env_from_feature() { # name
  git init -q --bare -b main "$T/origin.git"
  git clone -q "$T/origin.git" "$T/main" 2>/dev/null
  echo base >"$T/main/file.txt"
  git -C "$T/main" add file.txt
  git -C "$T/main" commit -q -m base
  git -C "$T/main" push -q origin main
  git -C "$T/main" checkout -q -b feature/person
  echo theirs >"$T/main/theirs.txt"
  git -C "$T/main" add theirs.txt
  git -C "$T/main" commit -q -m theirs
  git -C "$T/main" push -q origin feature/person
  mkdir -p "$T/main/.claude/worktrees"
  git -C "$T/main" worktree add -q -b "worktree-$1" "$T/main/.claude/worktrees/$1" feature/person
  ENV="$T/main/.claude/worktrees/$1"
  echo change >>"$ENV/file.txt"
  git -C "$ENV" commit -q -am change
}

# A stand-in for the engine's destroy, with the same guards and messages.
fake_engine() { # main
  mkdir -p "$1/scripts"
  cat >"$1/scripts/agent-env.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == destroy ]] || exit 2
name="$2" force="${3:-}"
main=$(pwd -P)
env="$main/.claude/worktrees/$name"
branch="worktree-$name"
uniq=$(git -C "$main" rev-list --count "refs/heads/$branch" --not --exclude="$branch" --branches --remotes)
if [[ "$force" != --force ]]; then
  [[ -z "$(git -C "$env" status --porcelain)" ]] || { echo "agent-env: '$name' has uncommitted changes; commit & push them, or rerun with --force to discard" >&2; exit 1; }
  [[ "$uniq" == 0 ]] || { echo "agent-env: '$name' has $uniq commit(s) that exist only on $branch; push or merge them, or rerun with --force to discard" >&2; exit 1; }
fi
git -C "$main" worktree remove --force "$env"
[[ "$uniq" == 0 ]] && git -C "$main" branch -D "$branch" >/dev/null
echo "agent-env: destroyed '$name'"
SH
  chmod +x "$1/scripts/agent-env.sh"
  git -C "$1" add scripts && git -C "$1" commit -q -m engine && git -C "$1" push -q origin main
}

# A WordPress env: a theme repo (the one that created the env) and a sibling
# plugin repo, both main checkouts inside a site with wp-config.php, plus the
# env's install clone holding a worktree of each on worktree-<name> with one
# commit. A stand-in agent-env-wp.sh destroy keeps the real one's guard order:
# the theme's unique commits are refused before any sibling is looked at.
make_wp_env() { # name [untouched-plugin]
  local r
  mkdir -p "$T/site/wp-content/themes" "$T/site/wp-content/plugins" "$T/envs/$1/wp-content/themes" "$T/envs/$1/wp-content/plugins"
  touch "$T/site/wp-config.php"
  for r in themes/theme plugins/plugin; do
    git init -q --bare -b main "$T/origin-${r#*/}.git"
    git clone -q "$T/origin-${r#*/}.git" "$T/site/wp-content/$r" 2>/dev/null
    echo base >"$T/site/wp-content/$r/file.txt"
    git -C "$T/site/wp-content/$r" add file.txt
    git -C "$T/site/wp-content/$r" commit -q -m base
    git -C "$T/site/wp-content/$r" push -q origin main
    if [[ "$r" == plugins/plugin && -n "${2:-}" ]]; then
      # The person's unpushed commit sits in the plugin checkout, and the env
      # never touches the plugin.
      echo theirs >"$T/site/wp-content/$r/theirs.txt"
      git -C "$T/site/wp-content/$r" add theirs.txt && git -C "$T/site/wp-content/$r" commit -q -m theirs
      git -C "$T/site/wp-content/$r" worktree add -q -b "worktree-$1" "$T/envs/$1/wp-content/$r" main
      continue
    fi
    git -C "$T/site/wp-content/$r" worktree add -q -b "worktree-$1" "$T/envs/$1/wp-content/$r"
    echo change >>"$T/envs/$1/wp-content/$r/file.txt"
    git -C "$T/envs/$1/wp-content/$r" commit -q -am change
  done
  THEME="$T/site/wp-content/themes/theme" PLUGIN="$T/site/wp-content/plugins/plugin"
  ENV="$T/envs/$1/wp-content/themes/theme" ENV_PLUGIN="$T/envs/$1/wp-content/plugins/plugin"
  mkdir -p "$THEME/.agent-env/wp/$1" "$THEME/scripts"
  printf 'AGENT_ENV_NAME="%s"\nAGENT_ENV_REL="wp-content/themes/theme"\nAGENT_ENV_INSTALL="%s"\nAGENT_ENV_SIBLINGS="wp-content/plugins/plugin"\n' \
    "$1" "$T/envs/$1" >"$THEME/.agent-env/wp/$1/meta.env"
  cat >"$THEME/scripts/agent-env-wp.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="$2" force="${3:-}" theme=$(pwd -P)
meta="$theme/.agent-env/wp/$name/meta.env"
install=$(sed -n 's/^AGENT_ENV_INSTALL="\(.*\)"$/\1/p' "$meta")
site=$(cd "$theme/../../.." && pwd -P)
b="worktree-$name"
uniq() { git -C "$1" rev-list --count "refs/heads/$b" --not --exclude="$b" --branches --remotes; }
if [[ "$force" != --force ]]; then
  [[ -z "$(git -C "$install/wp-content/themes/theme" status --porcelain)" ]] || { echo "'$name' worktree has uncommitted changes" >&2; exit 1; }
  u=$(uniq "$theme"); [[ "$u" == 0 ]] || { echo "'$name' has $u commit(s) only on $b; push/merge them, or --force" >&2; exit 1; }
  [[ -z "$(git -C "$install/wp-content/plugins/plugin" status --porcelain)" ]] || { echo "'$name' sibling worktree has uncommitted changes" >&2; exit 1; }
  u=$(uniq "$site/wp-content/plugins/plugin"); [[ "$u" == 0 ]] || { echo "'$name' has $u commit(s) only on $b in sibling" >&2; exit 1; }
fi
git -C "$theme" worktree remove --force "$install/wp-content/themes/theme"
git -C "$site/wp-content/plugins/plugin" worktree remove --force "$install/wp-content/plugins/plugin"
rm -rf "$install" "$theme/.agent-env/wp/$name"
echo "destroyed '$name'"
SH
  chmod +x "$THEME/scripts/agent-env-wp.sh"
}

# Squash-merge the env branch of the repo at $1 (its main checkout) on its origin.
land_repo() { # main-checkout worktree branch
  local c="$T/landing"
  git -C "$2" push -q origin "$3"
  git clone -q "$(git -C "$1" remote get-url origin)" "$c" 2>/dev/null
  git -C "$c" merge -q --squash "origin/$3" >/dev/null
  git -C "$c" commit -q -m squashed
  git -C "$c" push -q origin main
  git -C "$c" push -q origin --delete "$3"
  rm -rf "$c"
}

# ---------------------------------------------------------------------------
# env-status.sh

t_status_needs_a_pr_for_new_work() {
  make_env x
  capture_in "$ENV" env-status.sh
  expect_code 0
  check "name from the branch" jq -e '.name == "x" and .branch == "worktree-x" and .flavor == "lightweight"' <<<"$OUT"
  check "create-pr with one unpushed commit" jq -e '.repos[0] | .action == "create-pr" and .unpushed == 1 and .worktree == true and .remote_branch == false' <<<"$OUT"
}

t_status_merges_an_open_pr() {
  make_env x
  git -C "$ENV" push -q origin worktree-x
  echo '[{"number":7,"url":"u","isDraft":false,"baseRefName":"main","headRefOid":"a"}]' >"$GH_STATE/open-prs.json"
  capture_in "$ENV" env-status.sh
  check "merge" jq -e '.repos[0] | .action == "merge" and .unpushed == 0 and .remote_branch == true' <<<"$OUT"
}

t_status_flags_two_open_prs() {
  make_env x
  echo '[{"number":7},{"number":9}]' >"$GH_STATE/open-prs.json"
  capture_in "$ENV" env-status.sh
  check "multiple-prs" jq -e '.repos[0].action == "multiple-prs"' <<<"$OUT"
}

t_status_sees_a_squash_merge_as_done() {
  make_env x
  land x squash
  capture_in "$ENV" env-status.sh
  check "nothing to do" jq -e '.repos[0] | .action == "nothing" and .content_merged == true' <<<"$OUT"
}

t_status_blocks_on_uncommitted_changes() {
  make_env x
  echo wip >>"$ENV/file.txt"
  capture_in "$ENV" env-status.sh
  check "blocked-dirty" jq -e '.repos[0].action == "blocked-dirty"' <<<"$OUT"
}

t_status_by_name_from_the_main_checkout() {
  make_env x
  capture_in "$T/main" env-status.sh x
  expect_code 0
  check "finds the env's worktree" jq -e --arg d "$ENV" '.repos[0].dir == $d and .repos[0].action == "create-pr"' <<<"$OUT"
  capture_in "$T/main" env-status.sh
  expect_code 6
}

t_status_lists_a_wordpress_sibling() {
  make_wp_env x
  capture_in "$ENV" env-status.sh
  expect_code 0
  check "name from the branch, not the theme's directory" jq -e '.name == "x" and .flavor == "wordpress"' <<<"$OUT"
  check "theme then plugin" jq -e --arg p "$ENV_PLUGIN" --arg pm "$PLUGIN" \
    '(.repos | length) == 2 and .repos[1].dir == $p and .repos[1].main == $pm and .repos[1].action == "create-pr"' <<<"$OUT"
}

t_teardown_wordpress_after_squash_merges() {
  make_wp_env x
  land_repo "$THEME" "$ENV" worktree-x
  land_repo "$PLUGIN" "$ENV_PLUGIN" worktree-x
  capture_in "$THEME" teardown.sh x "$THEME"
  expect_code 0
  check "worktrees gone" [ ! -d "$ENV" ] && [ ! -d "$ENV_PLUGIN" ]
  check "theme branch deleted" no_branch "$THEME" worktree-x
  check "plugin branch deleted" no_branch "$PLUGIN" worktree-x
  check "plugin main pulled" [ "$(git -C "$PLUGIN" rev-parse HEAD)" == "$(git -C "$T/origin-plugin.git" rev-parse main)" ]
}

t_teardown_wordpress_refuses_a_dirty_sibling() {
  make_wp_env x
  land_repo "$THEME" "$ENV" worktree-x
  land_repo "$PLUGIN" "$ENV_PLUGIN" worktree-x
  echo wip >>"$ENV_PLUGIN/file.txt"
  capture_in "$THEME" teardown.sh x "$THEME"
  expect_code 1
  check "plugin worktree kept" [ -d "$ENV_PLUGIN" ]
}

t_teardown_wordpress_refuses_an_unmerged_sibling() {
  make_wp_env x
  land_repo "$THEME" "$ENV" worktree-x
  capture_in "$THEME" teardown.sh x "$THEME"
  expect_code 1
  check "worktrees kept" [ -d "$ENV" ] && [ -d "$ENV_PLUGIN" ]
}

t_status_cleans_up_a_merged_prs_branch() {
  make_env x
  git -C "$ENV" push -q origin worktree-x
  land_keep_branch x
  echo '[{"number":7,"url":"u","mergedAt":"2026-10-02T10:00:00Z"}]' >"$GH_STATE/merged-prs.json"
  capture_in "$ENV" env-status.sh
  check "cleanup" jq -e '.repos[0] | .action == "cleanup" and .remote_branch == true and .merged_prs[0].number == 7' <<<"$OUT"
}

t_status_offers_a_new_pr_after_an_earlier_merge() {
  make_env x
  land x squash
  echo more >>"$ENV/file.txt"
  git -C "$ENV" commit -q -am more
  echo '[{"number":7,"url":"u","mergedAt":"2026-10-02T10:00:00Z"}]' >"$GH_STATE/merged-prs.json"
  capture_in "$ENV" env-status.sh
  check "create-pr, with the earlier PR listed" jq -e '.repos[0] | .action == "create-pr" and (.merged_prs | length) == 1' <<<"$OUT"
}


t_status_from_the_sibling_worktree_finds_the_owner() {
  make_wp_env x
  capture_in "$ENV_PLUGIN" env-status.sh
  expect_code 0
  check "owner first, sibling second" jq -e --arg t "$ENV" --arg tm "$THEME" --arg p "$ENV_PLUGIN" \
    '.main == $tm and (.repos | length) == 2 and .repos[0].dir == $t and .repos[1].dir == $p' <<<"$OUT"
}

t_teardown_refuses_a_detached_head() {
  make_env x
  fake_engine "$T/main"
  git -C "$ENV" checkout -q --detach
  capture_in "$T/main" teardown.sh x "$T/main"
  expect_code 6
  check "worktree kept" [ -d "$ENV" ]
}

t_teardown_wordpress_refuses_an_unreadable_sibling() {
  make_wp_env x
  land_repo "$THEME" "$ENV" worktree-x
  land_repo "$PLUGIN" "$ENV_PLUGIN" worktree-x
  echo "gitdir: $T/nowhere" >"$ENV_PLUGIN/.git"
  capture_in "$THEME" teardown.sh x "$THEME"
  expect_code 1
  check "refused before forcing anything" [ -d "$ENV" ] && [ -d "$ENV_PLUGIN" ]
  check "says why" grep -q "can't read git status" <<<"$ERR"
}


t_status_targets_the_branch_the_env_started_from() {
  make_env_from_feature x
  capture_in "$ENV" env-status.sh
  check "base is the start branch" jq -e \
    '.repos[0] | .action == "create-pr" and .base == "feature/person" and .base_source == "started-from" and .started_from.ref == "feature/person"' <<<"$OUT"
}

t_status_stops_when_the_start_is_not_on_github() {
  make_env_from_feature x
  git -C "$T/main" push -q origin --delete feature/person
  capture_in "$ENV" env-status.sh
  check "unknown-base, falling back to main" jq -e '.repos[0] | .action == "unknown-base" and .base == "main"' <<<"$OUT"
}

t_status_stops_for_an_env_made_from_unpushed_work() {
  # The runtime's EnterWorktree branches from the checkout's HEAD, then the engine
  # renames the branch; here HEAD had a commit origin doesn't.
  make_env x
  echo local >"$T/main/local.txt"
  git -C "$T/main" add local.txt && git -C "$T/main" commit -q -m local
  git -C "$T/main" worktree add -q -b random-abc "$T/main/.claude/worktrees/y"
  git -C "$T/main" branch -m random-abc worktree-y
  echo change >>"$T/main/.claude/worktrees/y/file.txt"
  git -C "$T/main/.claude/worktrees/y" commit -q -am change
  capture_in "$T/main/.claude/worktrees/y" env-status.sh
  check "unknown-base from HEAD" jq -e '.repos[0] | .action == "unknown-base" and .started_from.ref == "HEAD"' <<<"$OUT"
  capture_in "$ENV" env-status.sh
  check "the env made from origin's main is fine" jq -e '.repos[0].action == "create-pr"' <<<"$OUT"
}

t_status_follows_an_open_prs_base() {
  make_env_from_feature x
  git -C "$ENV" push -q origin worktree-x
  echo '[{"number":7,"url":"u","isDraft":false,"baseRefName":"main","headRefOid":"a"}]' >"$GH_STATE/open-prs.json"
  capture_in "$ENV" env-status.sh
  check "merge into the PR's base" jq -e '.repos[0] | .action == "merge" and .base == "main" and .base_source == "open-pr"' <<<"$OUT"
}

t_teardown_checks_against_the_merged_prs_base() {
  make_env x
  fake_engine "$T/main"
  git -C "$T/main" push -q origin main:release
  git -C "$ENV" push -q origin worktree-x
  local c="$T/landing"
  git clone -q "$T/origin.git" "$c" 2>/dev/null
  git -C "$c" checkout -q release
  git -C "$c" merge -q --squash origin/worktree-x >/dev/null && git -C "$c" commit -q -m squashed
  git -C "$c" push -q origin release && git -C "$c" push -q origin --delete worktree-x
  echo '[{"number":7,"url":"u","baseRefName":"release","mergedAt":"x"}]' >"$GH_STATE/merged-prs.json"
  capture_in "$T/main" teardown.sh x "$T/main"
  expect_code 0
  check "removed after checking against release" [ ! -d "$ENV" ]
  check "says so" grep -q 'squash or rebase' <<<"$ERR"
  check "no local release branch made for the update" no_branch "$T/main" release
}

t_teardown_checks_against_the_start_branch() {
  make_env_from_feature x
  git -C "$ENV" push -q origin worktree-x
  local c="$T/landing"
  git clone -q "$T/origin.git" "$c" 2>/dev/null
  git -C "$c" checkout -q feature/person
  git -C "$c" merge -q --squash origin/worktree-x >/dev/null && git -C "$c" commit -q -m squashed
  git -C "$c" push -q origin feature/person && git -C "$c" push -q origin --delete worktree-x
  capture_in "$T/main" teardown.sh x "$T/main"
  expect_code 0
  check "removed" [ ! -d "$ENV" ]
  check "the checked-out feature branch fast-forwarded" \
    [ "$(git -C "$T/main" rev-parse feature/person)" == "$(git -C "$T/origin.git" rev-parse feature/person)" ]
}

t_status_without_a_start_record_still_spots_unmerged_work() {
  # git gc expires the reflog that records where the branch started.
  make_env_from_feature x
  git -C "$T/main" reflog expire --expire=now --all
  capture_in "$ENV" env-status.sh
  check "unknown-base with no start record" jq -e '.repos[0] | .action == "unknown-base" and .started_from == null and .base == "main"' <<<"$OUT"
}

t_status_without_a_start_record_passes_a_normal_env() {
  make_env x
  git -C "$T/main" reflog expire --expire=now --all
  capture_in "$ENV" env-status.sh
  check "create-pr" jq -e '.repos[0] | .action == "create-pr" and .started_from == null and .own_commits == 1' <<<"$OUT"
}

t_status_ignores_a_start_from_its_own_remote_branch() {
  make_env x
  git -C "$ENV" push -q origin worktree-x
  git -C "$T/main" worktree remove --force "$ENV"
  git -C "$T/main" branch -D worktree-x >/dev/null
  git -C "$T/main" worktree add -q -b worktree-x "$ENV" origin/worktree-x
  capture_in "$ENV" env-status.sh
  check "base main, not its own branch" jq -e '.repos[0] | .action == "create-pr" and .base == "main" and .started_from == null' <<<"$OUT"
}

t_status_leaves_an_untouched_sibling_alone() {
  make_wp_env x untouched
  capture_in "$ENV" env-status.sh
  check "theme needs a PR, plugin nothing" \
    jq -e '.repos[0].action == "create-pr" and .repos[1].action == "nothing" and .repos[1].own_commits == 0' <<<"$OUT"
}

t_teardown_passes_an_untouched_sibling() {
  make_wp_env x untouched
  land_repo "$THEME" "$ENV" worktree-x
  capture_in "$THEME" teardown.sh x "$THEME"
  expect_code 0
  check "both worktrees gone" [ ! -d "$ENV" ] && [ ! -d "$ENV_PLUGIN" ]
  check "the person's commit is still on their main" git -C "$PLUGIN" cat-file -e HEAD:theirs.txt
}

t_status_counts_work_another_branch_also_has() {
  # A backup branch, or a follow-up env stacked on this one, holds the same commit.
  make_env x
  git -C "$T/main" branch try-x worktree-x
  capture_in "$ENV" env-status.sh
  check "still needs its PR" jq -e '.repos[0] | .action == "create-pr" and .own_commits == 1' <<<"$OUT"
  git -C "$T/main" reflog expire --expire=now --all
  capture_in "$ENV" env-status.sh
  check "without a start record, ask rather than skip" jq -e '.repos[0].action == "unknown-base"' <<<"$OUT"
}

capture_in() { # dir script args...
  local d="$1"; shift
  set +e
  OUT=$(cd "$d" && $LIMIT "$SCRIPTS/$1" "${@:2}" 2>"$T/stderr")
  CODE=$?
  set -e
  ERR=$(cat "$T/stderr")
}

# ---------------------------------------------------------------------------
# teardown.sh

t_teardown_after_a_merge_commit() {
  make_env x
  fake_engine "$T/main"
  land x merge
  capture_in "$T/main" teardown.sh x "$T/main"
  expect_code 0
  check "worktree gone" [ ! -d "$ENV" ]
  check "branch gone" no_branch "$T/main" worktree-x
  check "main pulled to the merge" [ "$(git -C "$T/main" rev-parse HEAD)" == "$(git -C "$T/origin.git" rev-parse main)" ]
}

t_teardown_forces_past_a_squash_merge() {
  make_env x
  fake_engine "$T/main"
  land x squash
  capture_in "$T/main" teardown.sh x "$T/main"
  expect_code 0
  check "explains the force" grep -q 'squash or rebase' <<<"$ERR"
  check "worktree gone" [ ! -d "$ENV" ]
  check "branch deleted" no_branch "$T/main" worktree-x
}

t_teardown_refuses_unmerged_work() {
  make_env x
  fake_engine "$T/main"
  git -C "$ENV" push -q origin worktree-x
  git -C "$T/origin.git" update-ref -d refs/heads/worktree-x # remote copy gone, never merged
  capture_in "$T/main" teardown.sh x "$T/main"
  expect_code 1
  check "worktree kept" [ -d "$ENV" ]
}

t_teardown_refuses_uncommitted_changes() {
  make_env x
  fake_engine "$T/main"
  land x merge
  echo wip >>"$ENV/file.txt"
  capture_in "$T/main" teardown.sh x "$T/main"
  expect_code 1
  check "worktree kept" [ -d "$ENV" ]
}

t_teardown_refuses_to_run_inside_the_env() {
  make_env x
  fake_engine "$T/main"
  capture_in "$ENV" teardown.sh x "$T/main"
  expect_code 6
  check "worktree kept" [ -d "$ENV" ]
}

t_teardown_leaves_someone_elses_branch_checked_out() {
  make_env x
  fake_engine "$T/main"
  git -C "$T/main" checkout -q -b feature/person
  land x merge
  capture_in "$T/main" teardown.sh x "$T/main"
  expect_code 0
  check "still on their branch" [ "$(git -C "$T/main" branch --show-current)" == feature/person ]
  check "main fast-forwarded anyway" [ "$(git -C "$T/main" rev-parse main)" == "$(git -C "$T/origin.git" rev-parse main)" ]
}

t_teardown_lightweight_env() {
  make_env x
  land x squash
  capture_in "$T/main" teardown.sh x "$T/main"
  expect_code 0
  check "worktree gone" [ ! -d "$ENV" ]
  check "branch deleted" no_branch "$T/main" worktree-x
}

t_teardown_lightweight_refuses_unmerged_work() {
  make_env x
  capture_in "$T/main" teardown.sh x "$T/main"
  expect_code 1
  check "worktree kept" [ -d "$ENV" ]
}

# ---------------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^t_'); do
  run "${t#t_}" "$t"
done
echo
echo "$pass passed, $fail failed${failures:+:$failures}"
((fail == 0))
