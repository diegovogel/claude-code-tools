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

Enter plan mode via the `EnterPlanMode` tool, write the plan to the plan file specified in the plan-mode system message, then call `ExitPlanMode` to request approval. Do NOT present the plan inline in chat — the user wants plan mode specifically so they can comment on individual sections in the plan-file UI.

**This applies even in auto mode.** Auto mode's "do not enter plan mode unless the user explicitly asks" guidance does NOT apply here: invoking `/start-todoist-task` IS the explicit ask. The skill stops at the plan by design; auto mode does not override that.

The plan should have these sections:

1. **Goal** — one or two sentences in plain English, drawn from the task description + comments.
2. **Files to change** — bulleted list with a one-line "why" per file.
3. **Approach** — the shape of the change. Call out any non-obvious decisions or trade-offs and why you chose them.
4. **Risks / things to watch** — edge cases, places this could regress, areas you're less sure about.
5. **Test strategy** — what tests you'll add or update and at what layer (unit / composable / feature). Note explicitly if no test is warranted and why.
6. **Open questions** — anything you couldn't resolve in Phase 3 that you're flagging for the user to decide before implementation. Empty section is fine.

Do NOT start implementing. Wait for the user to comment on the plan or approve it via plan mode.

## Notes

- **Session title.** Claude Code auto-titles sessions from the first user prompt and there is no tool to rename a session mid-conversation. If the user passed `[short summary]`, echo it in the first sentence of your reply so the auto-title becomes useful. If they didn't, the title will be derived from your initial response — usually fine, occasionally generic.
- **Todoist comment posting is unrelated to this skill.** If you ever need to *post* a Todoist comment in a follow-up, use `td comment add` per the `todoist-cli` skill.
- **Project memory.** Before exploring, read `MEMORY.md` for the current project (per global CLAUDE.md). Existing project memories often answer questions you'd otherwise have to ask.
