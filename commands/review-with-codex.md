Run the current branch through automated Codex review cycles until it's clean or cycles are exhausted. Unlike `/pr-with-codex`, this does not create or post to a PR — it drives local Codex reviews against the branch diff.

## Phase 1: Preconditions

Verify the working tree is in a shape we can review, then proceed to Phase 2. If any check fails, STOP and report — do NOT proceed to Phase 2.

1. **On a branch**, not `main`.
   - If on a feature branch, continue to (2).
   - If on `main` AND there are uncommitted changes (tracked or untracked) that look related to the work just done in this conversation: propose a short kebab-case branch name based on the work, confirm it and the intended commit message with the user in a single question, then `git checkout -b <name>` and stage/commit the related files per your system prompt's commit workflow. Proceed once the branch exists with the commit on it.
   - If on `main` with no uncommitted changes (or no related ones): stop and ask the user what branch they want to review.
2. **Changes exist vs `main`**. Run `git diff --shortstat main...HEAD`. If empty, stop and tell the user there's nothing to review.
3. **Working tree is clean (no uncommitted changes).** If there are modifications remaining after step 1:
   - If the changes look related to the work being reviewed, draft and create a commit per your system prompt's commit workflow. Do this before starting cycles.
   - If you're not confident the changes belong with the branch's work, STOP and ask the user what to do with them. Suggest they stash or revert, but let them decide.
   - Untracked files follow the same rule: commit if clearly related, otherwise ask.

Once preconditions pass, proceed to Phase 2.

## Phase 2: Codex review cycles

Run up to **7 cycles**. Each cycle invokes `/codex:review` and acts on its findings.

### Step 1: Launch Codex review

Invoke the upstream `codex-companion.mjs` script via `Bash` with `run_in_background: true` (or foreground if the user passed `--wait` to `/review-with-codex`):

```bash
node "$(ls -t ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | head -1)" review --scope branch --base main
```

The glob + `ls -t | head -1` picks up the currently-installed Codex plugin version automatically, so version bumps don't break this skill.

**Always pass `--scope branch --base main` explicitly.** Without those flags the reviewer defaults to `--scope auto`, which picks up the working-tree diff first and will review only your uncommitted changes (typically unrelated ambient-tool churn) instead of the branch commits we came here to review. This produces a confident "no findings" on the wrong diff and has bitten this skill multiple times. If the branch is based on something other than `main`, substitute the right base — but set it explicitly, don't trust the default.

**Why this and not `Skill({ skill: "codex:review" })`?** The `/codex:review` skill has `disable-model-invocation: true` in its frontmatter, which the Skill tool enforces — it returns an error instead of running. Direct Bash invocation is the working alternative. If that flag is ever removed from `/codex:review`, prefer the Skill tool because it resolves `${CLAUDE_PLUGIN_ROOT}` correctly and auto-inherits future changes to the upstream skill — but still make sure the branch scope is set explicitly.

### Step 2: Wait for the task-completion notification

Claude Code will notify you when the background task finishes. The notification includes the task ID (matching the one `/codex:review` started) and an output file path. While waiting:

- **Do not** `sleep`, poll `BashOutput`, or proactively check progress.
- **Do not** re-invoke `/codex:review` for the same cycle.
- You MAY continue other work with the user (including discussing prior cycles' findings) — but when the notification arrives, process it per Step 3.

The reliability of this pattern depends on you acting on the notification when it lands. The system guarantees the notification fires; the discipline to process it belongs to this skill.

**Foreground override**: if the user passed `--wait`, the Codex command runs in the foreground and you get the output in the Skill tool's return value. Skip the notification-wait and go directly to Step 3.

### Step 3: Process the task output

Read the output file path from the notification (or use the Skill tool's direct return value in foreground mode). The output is the `/codex:review` skill's verbatim response, which is the Codex review text — a free-form markdown block.

**Always print the findings verbatim in the main chat before doing anything else with them.** The raw Codex output inside the Bash tool result is collapsed by default and the user won't see it without expanding — which defeats the point of running a review they can follow. Quote the review section (from the `# Codex Review` heading through the last finding) as a top-level markdown blockquote or code block in your message, then add your summary and plan below it. Do not paraphrase in place of quoting; the user wants Codex's words first.

Parse the findings as follows:

- **No findings**: if the review text indicates no concerns ("no issues", "looks good", "no findings", or similar), the branch is clean. Say so and proceed to **Phase 3: Create PR** below.
- **One or more findings**: each finding typically includes a severity tag (P1/P2), a file:line reference, a description, and a recommendation. Quote the findings verbatim, then proceed to "Addressing feedback" below.
- **Unparseable or ambiguous output**: if the review text doesn't clearly convey findings or no-findings, show the raw output to the user and ask how to proceed.

### Addressing feedback

For each finding:

- **Fix it** unless you have a good reason not to, such as:
  - Context Codex lacks (project convention, architectural decision, data Codex can't see)
  - A deliberate trade-off already discussed with the user
  - The suggestion is wrong or introduces its own problems
- **Verify tool-behavior claims before implementing.** When a finding's correctness depends on how an external tool behaves at runtime (cURL flag semantics, ffmpeg parsing, DB engine quirks), reproduce that behavior locally before coding the fix. The companion log shows `Command completed... (exit 0)` for tool calls Codex made during review — but `exit 0` only means the shell wrapper ran; the underlying tool may have errored on stderr. Don't take Codex's tool-call exploration as proof. A unit test that just asserts the format of your fix won't catch a tool-level rejection — the regression test has to exercise the real tool path, or you verify manually and note that in the commit message.
- **When skipping**: briefly note why in the commit message or the response summary. Unlike `/pr-with-codex`, there's no PR comment thread — the human record lives in your commit messages and the conversation.
- **Write a regression test** for every accepted finding, as part of the same commit, subject to two conditions:
  1. The codebase already has a test system (runner + existing tests). Don't stand one up just for this.
  2. A test is feasible and worthwhile — a judgment call. The test should encode the specific failure mode Codex described: a behavior that would have shipped broken if the finding had landed. Follow the codebase's existing test conventions (same framework, fixtures, file layout). You should have enough confidence in the test that you believe it would have failed pre-fix; if in doubt, revert the fix locally, re-run, and check.

  Some kinds of findings genuinely don't warrant a dedicated test — the list below is illustrative, not exhaustive, and the judgment call belongs to you:
  - Pure type errors where a type-checker (`tsc`, `mypy`, etc.) is already the regression guard.
  - Pure refactors or rename-only changes with no behavioral difference to assert.
  - Docs / comment-only changes.
  - Complex UI race conditions that would need a real browser plus fake timers, when the codebase has no precedent for that style of test.
  - Integrations against live external services with no fixture / fake pattern in the codebase.

  Default to writing the test for P1 / P2 findings. P3 is more often a judgment call. **If you're genuinely unsure whether a test is worth it, surface it to the user rather than silently skipping.** If you decide to skip, briefly note why in the commit message.

  **Why this matters:** drift between iterated fixes is the dominant failure mode in this skill. Cycle N's fix can miss a call site or collide with cycle N-K's behavior; a regression test at each cycle locks the intent in place so a later cycle's code change can't silently re-introduce the bug.

After fixing, commit the changes (one commit per cycle is fine; title it with the cycle number, e.g. "Address Codex cycle 2: ...") and push. Do not amend or force-push.

Then return to Step 1 for the next cycle.

### Early exit on repeat findings

If Codex re-raises substantively the same finding you already pushed back on in a previous cycle (same root cause, same recommendation, even if rephrased or re-prioritized P1↔P2), that's the same signal the cycle-7 evaluation below is checking for. Stop the loop, summarize what's repeating and what you've rejected, and ask the user whether to continue or wrap up. Don't keep cycling mechanically just because you haven't hit the cap — the loop's value is finding *new* issues, and a Codex that's stuck on a rejected point won't get unstuck by another cycle.

This applies once you've made the same push-back twice. A finding that was raised, rejected, raised again, and rejected again — that's the pattern to stop on. New findings in the same cycle are still addressed normally; only the loop itself is what stops.

## Cycle limit

**Max 7 cycles.** If cycle 7 ends with findings still present:

- Address them (same as any other cycle), then evaluate:
  - Are the remaining / newest findings meaningful and actionable?
  - Or is Codex cycling on the same low-value suggestions you've already pushed back on?
- Report to the user with a clear recommendation: **"continue (and why)"** or **"stop (and why)"**. Do NOT automatically start cycle 8 without the user's approval.
- **Do NOT proceed to Phase 3** after cycle 7 unless the user approves. The PR step assumes a clean review.

## Phase 3: Create PR

Triggered only when a cycle returns no findings (at any cycle count up to 5). Do NOT run this phase if cycles hit the cap with findings still present.

Follow your standard PR-creation workflow from your system prompt's "Creating pull requests" section. Do NOT duplicate those instructions here — use the built-in workflow verbatim (status/diff/log in parallel, draft title + body, push the branch if needed, run `gh pr create` with a HEREDOC body, return the PR URL).

Rationale: if Codex signs off, the branch is ready for review. Automating the PR step saves a manual beat and keeps the workflow symmetric with `/pr-with-codex` (which creates the PR first, then reviews; this skill reviews first, then creates the PR).

If anything in Phase 3 fails — push rejected, `gh pr create` errors out, branch already has an open PR, etc. — report the error to the user. The Codex-clean result still stands.

## Why this skill exists

`/pr-with-codex` uses the Codex GitHub connector, which requires a PR and polls GitHub for comments. For reviewing a branch before (or without) opening a PR — or just to iterate faster — `/codex:review` is a better fit: runs locally, faster turnaround, no PR noise. This skill automates the cycle loop that you'd otherwise run by hand ("`/codex:review`, fix findings, commit, repeat").

Background-by-default is intentional: it lets the user chat with you while Codex runs. The reliability depends on acting on the task-completion notification when it arrives, not on this skill's good intentions — so Step 2 spells out the contract explicitly.
