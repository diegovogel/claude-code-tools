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
- **Codex review** — a table of its findings: the claim, whether you verified it in the code, and what you did with it (accepted, or rejected with the reason).
- **Verification** — how to run and check the change end to end.

### Phase 4b: Codex reviews the plan

Before `ExitPlanMode`, have Codex review the written plan in the Codex plugin's **read-only `task` mode**. It reviews the plan in its entirety, but the testing plan is where it must not skim. The bar it judges tests against: each one meaningfully validates behaviour; no smoke tests and no testing for the sake of testing; each is capable of failing when the behaviour it guards regresses; it tests what the code does rather than how; it mocks only at true I/O boundaries; and it does not duplicate coverage that already exists. Ask it to say, per proposed test, whether it clears that bar, and to name any test that would pass for the wrong reason or still pass with the guard it protects deleted.

**How to run it.** The `codex-rescue` subagent that would normally wrap this is denied in settings, so call the companion script directly, with **no `--write`**, which makes the sandbox read-only. Pipe the prompt in on stdin with the plan file embedded verbatim, and run it in the background: it takes several minutes, and reading the repo edits nothing, so it is allowed in plan mode.

```bash
{ cat <<'EOF'
<task>...</task>
<plan>
EOF
cat <the plan file>
cat <<'EOF'
</plan>
<structured_output_contract>...</structured_output_contract>
<grounding_rules>...</grounding_rules>
<dig_deeper_nudge>...</dig_deeper_nudge>
EOF
} | node "$(ls -t ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | head -1)" task
```

Compose the prompt per the `codex:gpt-5-4-prompting` skill (load it first): a `<task>` block naming the repo, the files to read and the testing bar above; the plan embedded verbatim; a `<structured_output_contract>` asking, in order, for a verdict on the plan's central claim with file:line evidence, testing-plan findings most severe first, other findings, proposed tests it would drop, and tests it would add only if they clear the bar, with each finding tagged CONFIRMED (it read the code that proves it) or HYPOTHESIS; `<grounding_rules>` requiring file:line citations from files it actually opened and forbidding production-code refactors when the change is meant to be narrow; and a `<dig_deeper_nudge>` listing the specific fixture, harness or framework assumptions you are least sure of, so those get checked rather than assumed.

**Verify every claim before acting on it.** Codex reads the code, but it does not know the project's conventions, the decisions recorded in CLAUDE.md, or what the user has already ruled on. For each finding, read the code it cites. Accept it into the plan only if it holds; reject it, with a one-line reason, when you have context Codex lacks or the suggestion is wrong. Record every outcome in the plan's Codex review table, and every rejection also under trade-offs, so the user can see what was pushed back on and why. Take most seriously any finding that a proposed test cannot fail: try to construct the regression it would catch, and if you cannot, drop or rework the test.

If the run fails before Codex reads anything, stop and ask the user rather than presenting the plan as reviewed. An authentication error ("Your access token could not be refreshed because your refresh token was already used") means the CLI's login is dead even while `codex login status` still says logged in; the fix is `codex logout` then `codex login` in the user's browser, after which rerun. Never skip the review silently.

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
