Kick off work on a Todoist task: fetch the task and all its context, explore the codebase, ask clarifying questions if needed, then present a plan in plan mode. Does NOT implement — stops at the plan.

## Usage

```
/start-todoist-task <url> [short summary]
```

- `<url>` (required) — Todoist task URL. The task ID is the alphanumeric segment at the end of the URL (after the slug, e.g. `6gVHc8c2MmGxGGcP`).
- `[short summary]` (optional) — A few words describing the work. Used only to give the session a deterministic title (see Notes below).

## Phase 1: Fetch the task and all context

Use the `td` CLI (per the `todoist-cli` skill) to fetch:

1. **The parent task.** Run `td task view <url> --json` (the URL the user pasted works directly as a ref).
2. **All sub-tasks (recursive).** Run `td task list --parent <url> --json`. Repeat for each sub-task that itself has sub-tasks, until the tree is fully expanded. Read each sub-task's content and description.
3. **All comments on the parent task AND on every sub-task.** Run `td comment list <ref> --json`. Do NOT skip comments. They frequently carry the most recent decisions, screenshots, scope refinements, or pivots.
4. **Attachments on those comments.** For any comment whose JSON has `fileAttachment` with a `fileUrl`, run `td attachment view <fileUrl>` (the skill's warning against `curl + Read` for images applies). Skip URL-preview-only "attachments" (no `fileUrl`).

If the URL doesn't parse as a Todoist task URL, stop and ask the user for a valid one rather than guessing.

Quote the task title verbatim early in your response so the user can confirm you fetched the right task. If a `[short summary]` arg was passed, weave it into the first sentence of your response so the auto-generated session title picks it up.

## Phase 2: Explore the codebase

Spawn the **Explore** subagent for breadth. Brief it with:
- The task title.
- A one-paragraph summary of what the task is asking for (synthesized from parent + sub-tasks + comments).
- Your initial guess at what areas/files are involved (so it can confirm or correct).

Ask Explore to return:
- Entry points for the affected feature.
- Existing patterns the change should match (composables, services, naming conventions, test layout).
- A list of files that will likely need to change, with one-line rationale per file.

Then read the specific files yourself before planning. Explore's report is a starting point, not a substitute for direct reading of the code you intend to change.

## Phase 3: Identify gaps and ask clarifying questions

Even in **auto mode**, pause here if anything is genuinely ambiguous. Auto mode's "minimize interruptions" guidance does NOT override this phase — the cost of building the wrong plan and discovering it during implementation is higher than a short Q&A round.

Threshold:
- **Ask** when a reasonable assumption can't be made, or when the wrong assumption would meaningfully change the plan (different files touched, different UX, different acceptance criteria, different testing strategy).
- **Don't ask** about routine decisions (variable names, exact line to insert at, lint-style choices, well-established project conventions). State the assumption inline in the plan instead.

Group questions: prefer one consolidated message with a numbered list over several back-and-forth exchanges. If you have zero genuine questions, say so explicitly ("No clarifying questions — proceeding to plan.") and continue to Phase 4.

## Phase 4: Plan in plan mode

Enter plan mode via the `EnterPlanMode` tool, write the plan to the plan file specified in the plan-mode system message, have Codex review it (Phase 4b), fold the verified findings back into the file, then call `ExitPlanMode` to request approval. Do NOT present the plan inline in chat — the user wants plan mode specifically so they can comment on individual sections in the plan-file UI.

**This applies even in auto mode.** Auto mode's "do not enter plan mode unless the user explicitly asks" guidance does NOT apply here: invoking `/start-todoist-task` IS the explicit ask. The skill stops at the plan by design; auto mode does not override that.

### Plan structure

Lead with what the user has to decide or could be surprised by. The technical detail comes after, because the Codex review in Phase 4b is what checks that part; the user reads the top of the file, Codex reads the bottom. The first seven sections, in this order:

1. **Goal and high-level approach** — one or two sentences in plain English drawn from the task description and comments, then the shape of the change in a few lines.
2. **Assumptions made during planning** — anything the plan takes as given that the task did not state.
3. **Questions asked during planning** — what Phase 3 asked and what the answer was. "None" is a valid entry; say why nothing needed asking.
4. **Trade-off decisions made without input** — every choice the user could reasonably have wanted a say in: the option taken, the option not taken, and the cost. Include Codex suggestions you rejected, with the reason.
5. **Risks / things to watch** — edge cases, places this could regress, areas you're less sure about.
6. **User-facing copy** — every string a visitor, customer, editor or admin will read, verbatim. "None" if the change carries no copy.
7. **Open questions** — anything unresolved that the user should decide before implementation. Empty section is fine.

Then, under a `## Technical detail` divider:

- **Files to change** — bulleted list with a one-line "why" per file.
- **Approach** — the concrete shape of the change, naming the existing helpers and patterns it reuses.
- **Test strategy** — what tests you'll add or update and at what layer (unit / composable / feature), and for each the regression it would catch. A test that cannot fail is not a test. Note explicitly if no test is warranted and why.
- **Codex review** — a table of its findings: the claim, whether you verified it in the code, and what you did with it (accepted, or rejected with the reason). One row per finding and one per test Codex proposed. The section names the file or files beside the plan that hold Codex's raw output (Phase 4b).
- **Verification** — how to run and check the change end to end.

### Phase 4b: Codex reviews the plan

Before `ExitPlanMode`, have Codex review the written plan in the Codex plugin's **read-only `task` mode**. It reviews the plan in its entirety, but the testing plan is where it must not skim. The bar it judges tests against: each one meaningfully validates behaviour; no smoke tests and no testing for the sake of testing; each is capable of failing when the behaviour it guards regresses; it tests what the code does rather than how; it mocks only at true I/O boundaries; and it does not duplicate coverage that already exists. Ask it to say, per proposed test, whether it clears that bar, and to name any test that would pass for the wrong reason or still pass with the guard it protects deleted.

Three further asks. Have it enumerate every write path and every output sink the change touches and name the ones the plan does not cover. Have it state, per finding, whether the path is reachable in this project's current configuration, so an unreachable path is reported as unreachable rather than as a P1. Tell it not to run the test suite: the sandbox is read-only, so the run fails on temp-dir writes and comes back as a finding about validation instead of about the plan.

**How to run it.** The `codex-rescue` subagent that would normally wrap this is denied in settings, so call the companion script directly, with **no `--write`**, which makes the sandbox read-only. Every path is written literally: no command substitution, no shell variables, no heredocs. That is the shape `/review-with-codex` uses, and it also passes the stricter Bash vetting of a session bound to a worktree, which a session cannot detect until a command is refused.

1. Resolve the installed plugin version: `ls -t ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | head -1`. It prints one absolute path, used verbatim below. If it prints nothing or `no matches found`, the plugin is missing; stop and ask rather than guessing a version.
2. Build the prompt in the session's scratchpad directory, which plan mode lets you write. With the `Write` tool, write `codex-plan-review.head.md` (the `<task>` block through the opening `<plan>` tag) and `codex-plan-review.tail.md` (the closing `</plan>` tag through `<dig_deeper_nudge>`), then assemble with one `cat`:

```bash
cat "<scratchpad>/codex-plan-review.head.md" "<plan file>" "<scratchpad>/codex-plan-review.tail.md" > "<scratchpad>/codex-plan-review.md"
```

A file rather than an inline argument: when the prompt is the sole argument after `task`, the companion re-tokenizes it, and any `--write`, `--model` or other flag token inside the plan is consumed as a flag. A file rather than stdin, so the exact prompt survives for a re-run or a delta pass.

3. Launch with the Bash tool's `run_in_background: true`, the path from step 1 written out literally, the output copied into the scratchpad:

```bash
set -o pipefail; node /Users/diego/.claude/plugins/cache/openai-codex/codex/<version>/scripts/codex-companion.mjs task --prompt-file "<scratchpad>/codex-plan-review.md" | tee "<scratchpad>/codex-plan-review.codex.md"
```

Do not pass the companion's own `--background`: on `task` it detaches a worker, prints a one-line job id and exits 0, so the file would hold only that line. It takes several minutes, and reading the repo edits nothing, so plan mode allows the launch. Never run `task --help` to check flags: anything after `task` is the prompt, so it opens a real Codex turn. `node <script> help` prints the usage safely, but its `task` line omits `--prompt-file`; the flag is declared in `handleTask`, so grep the script for `prompt-file` rather than trusting the usage text.

**Launching ends the turn.** The background run re-invokes you with a task notification when it finishes. In the launching turn, say in a sentence that the review is running, then stop: do not poll, and do not call `ExitPlanMode` until the findings are folded in. Do not edit the plan file while Codex reads it either: it reviews the embedded copy, and a plan that moved on has to be re-embedded and re-run.

**Check the run before reading it.** `set -o pipefail` makes the Bash exit status the companion's rather than `tee`'s, and that status, not the file, says whether the review ran. The companion prints its result only at exit, so a run that fails or is stopped leaves the file empty or holding only the failure message. On a non-zero exit, read the file for the reason, delete it, and apply the failure paragraph below. `node <literal path> result`, run from the same directory, re-prints a completed run's output if the copy was lost.

**Persist the record beside the plan.** When the notification lands, copy the output in its own Bash call to `<plan path without .md>.codex.md`. The plans directory is outside plan mode's write carve-out, so this call may ask for permission; if it is refused, the scratchpad copy is the record until plan mode ends, then copy it. The harness's own task output file disappears with the session, which is why the copy exists. Name every record file in the plan's Codex review section.

Compose the prompt per the `codex:gpt-5-4-prompting` skill (load it first): a `<task>` block naming the repo, the files to read, the testing bar above and the three further asks; the plan embedded verbatim; a `<structured_output_contract>` asking, in order, for a verdict on the plan's central claim with file:line evidence, testing-plan findings most severe first, other findings, proposed tests it would drop, tests it would add only if they clear the bar, and what it did not verify, with each finding tagged CONFIRMED (it read the code that proves it) or HYPOTHESIS; `<grounding_rules>` requiring file:line citations from files it actually opened and forbidding production-code refactors when the change is meant to be narrow; and a `<dig_deeper_nudge>` listing the specific fixture, harness or framework assumptions you are least sure of, so those get checked rather than assumed.

**Verify every claim before acting on it.** Codex reads the code, but it does not know the project's conventions, the decisions recorded in CLAUDE.md, or what the user has already ruled on. For each finding, read the code it cites. Accept it into the plan only if it holds; reject it, with a one-line reason, when you have context Codex lacks or the claim is wrong. Record every outcome in the plan's Codex review table, and every rejection also under trade-offs, so the user can see what was pushed back on and why. Take most seriously any finding that a proposed test cannot fail: try to construct the regression it would catch, and if you cannot, drop or rework the test.

Three disposition rules (the five reviews behind them are in the `codex-plan-review-field-record` memory):

- **Impact and remedy are separate questions.** A finding is rejected on two grounds only: its impact is refuted, with the measurement or code citation in the table, or a decision already settles it (a Phase 3 answer, CLAUDE.md, project memory), with that decision in the table. A remedy you dislike is a reason to choose a different remedy, not to drop the finding.
- **Codex's proposed tests are a checklist.** Each gets its own row in the table, declined only by naming the existing test that already covers the regression or the reason the regression cannot occur.
- **Re-review when the plan changed materially.** If folding the findings added a mechanism or a write path, or dropped or narrowed a guard, run one more pass on the same thread: step 3's command with `--resume-last` added, the delta prompt (only what changed) in a second scratchpad file passed with `--prompt-file`, and `tee -a` so the output is appended to the record after a `---` line. `--resume-last` finds the newest `task` run this Claude session made from this checkout, so run it in the same session and directory; if it reports "No previous Codex task thread was found for this repository", run a fresh full review instead. Wording changes do not warrant a second pass.

If the run fails before Codex reads anything, stop and ask the user rather than presenting the plan as reviewed. An authentication error ("Your access token could not be refreshed because your refresh token was already used") means the CLI's login is dead even while `codex login status` still says logged in; the fix is `codex logout` then `codex login` in the user's browser, after which rerun. "You've hit your usage limit" means the Codex plan's quota is spent; the user resets it, then rerun. Never skip the review silently.

The message that ends the fold-in turn (the one that calls `ExitPlanMode`) says that the review ran, how many findings were accepted and rejected, and where the record file is. Unlike `/review-with-codex`, the findings are not quoted in chat: the plan-file UI shows the Codex review table and the record file keeps the raw text. Do not paste the plan into chat.

Do NOT start implementing. Wait for the user to comment on the plan or approve it via plan mode.

## Phase 5: Isolated environment (only after plan approval)

When the user approves the plan and implementation begins, do the work in an **isolated agent environment**. Invoke the **`agent-environments` skill** and let it own the mechanics: it detects whether the repo already has an environment system, knows the per-stack and sub-component specifics (e.g. a WordPress theme/plugin nested in a full install), and enforces the cardinal rules. Do NOT re-encode the detection or the worktree/provision/serve commands here; that all lives in the skill.

Policy for this command:
- **If the repo already has an environment system**: operate it as the skill directs (create or adopt an env for this task), then implement, test, and run the skill's pre-PR workflow from inside it. The skill owns that workflow, including its commit/push policy and where it stops. Note it stops *before* the PR, so this command never ends in a PR on its own.
- **If it does not**: ask the user before setting one up ("This repo has no agent-environment system. Set one up for isolated work, or implement in place?"). Run the skill's setup path only if they agree; otherwise implement in place. Setup is one-time per repo, so later tasks won't re-prompt.

Once inside an env, follow the skill's cardinal rules (run the env's own `serve`, never the project's main dev command, while inside an env; re-anchor after any interruption; tear down only via the guarded `destroy`).

## Notes

- **Session title.** Claude Code auto-titles sessions from the first user prompt and there is no tool to rename a session mid-conversation. If the user passed `[short summary]`, echo it in the first sentence of your reply so the auto-title becomes useful. If they didn't, the title will be derived from your initial response — usually fine, occasionally generic.
- **Todoist comment posting is unrelated to this skill.** If you ever need to *post* a Todoist comment in a follow-up, use `td comment add` per the `todoist-cli` skill.
- **Project memory.** Before exploring, read `MEMORY.md` for the current project (per global CLAUDE.md). Existing project memories often answer questions you'd otherwise have to ask.
