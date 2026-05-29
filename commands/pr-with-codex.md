Create a pull request and run it through automated Codex review cycles until the PR is clean or cycles are exhausted.

## Phase 1: Create the PR

Follow your standard PR-creation workflow from your system prompt's "Creating pull requests" section. Do NOT duplicate those instructions here — use the built-in workflow verbatim (status/diff/log in parallel, draft title + body, push the branch if needed, run `gh pr create` with a HEREDOC body, return the PR URL).

If anything in Phase 1 fails — push rejected, `gh pr create` errors out, branch already has an open PR, etc. — STOP immediately and report the error to the user. Do NOT proceed to Phase 2.

Once the PR exists, capture the owner, repo name, and PR number. You'll need them for every cycle in Phase 2.

## Phase 2: Codex review cycles

Run up to **5 cycles**. For each cycle:

### Step 1: Start the polling script in the background

Invoke:

```
~/.claude/scripts/pr-with-codex/poll-codex.sh <owner> <repo> <pr_number>
```

with the Bash tool's `run_in_background: true` parameter.

**The script does all the work itself**: it posts `@codex review`, sleeps 60 s, verifies the `chatgpt-codex-connector[bot]` added an `eyes` reaction (re-posting once if not), then polls both the `/pulls/{n}/reviews` and `/issues/{n}/comments` endpoints every 60 s for up to 15 minutes.

### Step 2: Wait for the task-completion notification

Claude Code will notify you automatically when the background task finishes. While you're waiting:

- **Do not** `sleep`, poll `BashOutput`, or proactively check the task's progress.
- **Do not** re-invoke the script.
- **Do not** try to reproduce the polling logic yourself.
- You may continue other unrelated work if the user asks, but you must come back and process the notification when it arrives.

This "start it and wait for the notification" pattern is the whole point of running the script in the background. The loop is in bash, not in your own discipline, so polling reliability is independent of how distracted you get.

### Step 3: Process the task output

When the notification fires, read the task's output file. Exit code tells you what happened:

- **Exit 0**: Codex posted a response. Stdout is a JSON envelope in one of two shapes depending on whether Codex found issues or not. Codex's own response-type conventions:
  - **Has suggestions** → Codex posts a PR review. Envelope shape:
    ```
    {"type": "review", "data": {...review...}, "inline_comments": [{id, path, line, body}, ...]}
    ```
    The review `body` is always a generic "Here are some automated review suggestions for this pull request." header with NO actionable content. The real findings live in `inline_comments`, which the script has already fetched from `/pulls/{n}/reviews/{review_id}/comments`. Iterate `inline_comments` to address each finding.

    **Always quote each `inline_comments` finding verbatim in the main chat before doing anything else with them.** The raw JSON inside the Bash tool result is collapsed by default and the user won't see Codex's actual words without expanding it — which defeats the point of running a review they can follow. Format each finding as a markdown bullet citing `path:line` and quoting the `body` (Codex's exact phrasing, not a paraphrase), then add your summary and plan below. Do not paraphrase in place of quoting; the user wants Codex's words first.
  - **No issues** → Codex posts a plain issue comment whose body contains "Didn't find any major issues" (or similar "no concerns" phrasing). Envelope shape:
    ```
    {"type": "comment", "data": {...comment...}}
    ```
    When `type` is `"comment"`, check `data.body` for the no-concerns phrasing. If it matches → PR is ready, report success with the PR URL and STOP.
  - **Other cases**: if a review arrives with an empty `inline_comments` array, or a plain comment that doesn't contain the no-concerns phrasing, treat the body as free-text feedback. Report to the user and ask how to proceed.

- **Exit 2**: 15 minutes elapsed with no Codex response. Report the timeout to the user and ask whether to retry (runs a fresh cycle) or stop.

- **Exit 3**: Script-level error (missing args, `gh`/`jq` not on PATH, failed to post the trigger comment, etc.). The error message is on stderr in the task output. Report it to the user and stop.

### Addressing feedback

For each item Codex flagged:

- **Fix it** unless you have a good reason not to, such as:
  - Context Codex lacks (project convention, architectural decision, data Codex can't see)
  - A deliberate trade-off already discussed with the user
  - The suggestion is wrong or introduces its own problems
- **Verify tool-behavior claims before implementing.** When a finding's correctness depends on how an external tool behaves at runtime (cURL flag semantics, ffmpeg parsing, DB engine quirks), reproduce that behavior locally before coding the fix. Codex grounds many findings in tool exploration you can't see, and shell exit codes from any wrappers it ran don't prove the underlying tool accepted the input. A unit test that just asserts the format of your fix won't catch a tool-level rejection — the regression test has to exercise the real tool path, or you verify manually and note that on the PR.
- **When skipping**, post a reply on that specific review comment explaining why. Note: Codex does not reliably read reply comments as context in subsequent reviews, so this is for the human record, not to convince Codex.
- **Write a regression test** for every accepted finding, as part of the same commit, subject to two conditions:
  1. The codebase already has a test system (runner + existing tests). Don't stand one up just for this.
  2. A test is feasible and worthwhile — a judgment call. The test should encode the specific failure mode Codex described: a behavior that would have shipped broken if the finding had landed. Follow the codebase's existing test conventions (same framework, fixtures, file layout). You should have enough confidence in the test that you believe it would have failed pre-fix; if in doubt, revert the fix locally, re-run, and check.

  Some kinds of findings genuinely don't warrant a dedicated test — the list below is illustrative, not exhaustive, and the judgment call belongs to you:
  - Pure type errors where a type-checker (`tsc`, `mypy`, etc.) is already the regression guard.
  - Pure refactors or rename-only changes with no behavioral difference to assert.
  - Docs / comment-only changes.
  - Complex UI race conditions that would need a real browser plus fake timers, when the codebase has no precedent for that style of test.
  - Integrations against live external services with no fixture / fake pattern in the codebase.

  Default to writing the test for findings that describe a real bug or security gap. Pure-style suggestions are more often a judgment call. **If you're genuinely unsure whether a test is worth it, surface it to the user rather than silently skipping.** If you decide to skip, briefly note why in the commit message.

  **Why this matters:** drift between iterated fixes is the dominant failure mode in this skill. Cycle N's fix can miss a call site or collide with cycle N-K's behavior; a regression test at each cycle locks the intent in place so a later cycle's code change can't silently re-introduce the bug.

After fixing, push as new commits to the same branch. Do not amend or force-push.

## Cycle limit

**Max 5 cycles.** If cycle 5 ends with changes still requested:

- Address them (same as any other cycle), then evaluate:
  - Are the remaining / newest findings meaningful and actionable?
  - Or is Codex cycling on the same low-value suggestions you've already pushed back on?
- Report to the user with a clear recommendation: **"continue (and why)"** or **"stop (and why)"**. Do NOT automatically start cycle 6 without the user's approval.

## Why this skill exists

Previous versions of this workflow lived inline in `CLAUDE.md` and had you poll for Codex responses on your own discipline ("check back every 2 minutes"). That turned out to be unreliable — polling in prose instructions is easy to forget between turns. The fix is to put the poll loop inside a bash script and run it as a background task: real timer, real exit code, automatic completion notification. Your only job between trigger and result is to wait for the notification and then act.
