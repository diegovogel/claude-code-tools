Generate a manual QA procedure from this session's changes and walk through it interactively. The user drives the UI; you verify backend signals (logs, DB, network). Three phases: build the procedure, walk it through together, then clean up.

## When NOT to use

If the change has no UI surface — CLI-only, API-only, pure backend, library code — REFUSE the request. Tell the user manual QA is meant for end-to-end UI behavior that's hard to cover with automation, and these changes are better validated by the project's automated test suite.

How to detect: scan the diff for UI-touching files (templates, components, JSX/TSX/Vue/Svelte, HTML, layouts, route handlers that render, CSS that affects user-visible behavior). If none, decline.

## Phase 1 — Build the QA procedure

Inputs to consider:
- `git status --short` (untracked, modified, staged)
- `git diff <base>...HEAD` where `<base>` is the project's main branch (check CLAUDE.md, default to `main`)
- Conversation history for any decisions, reverts, or pivots that aren't visible in the final diff

Project-specific context — ask the user before drafting if you're unsure about any of these:
- Which UI to test (URL, app, route)
- Which logs to tail (container, file, service)
- Which DB to query (engine, connection details, schema)
- Which credentials / badges / test accounts are safe to use

### Procedure structure

The procedure has three named sections you'll print verbatim to the user, then walk through in Phase 2:

**Setup** — anything to do before Step 1: capture baselines (DB row counts, log line numbers, recent commits), bring up services, open log tails, surface the exact app URL. Anything that gives "before" numbers so deltas are unambiguous.

**Steps** — numbered Step 1, Step 2, ... covering every behavior the diff changes. For each Step, the printed body has three labeled parts:
- **What you do** — 1-3 sentences max, concrete UI actions including exact values to type
- **Expected (UI)** — what the user should see (alert text, modal opening, chart point appearing)
- **My checks** — what you'll verify (DB rowcount delta, log line, network request, file existence)

**Cleanup** — the closing checklist Phase 3 will run.

### Step ordering principles

- Simplest path first (in-spec / happy path) so the user gets confidence the wiring is right before edge cases.
- Each Step's setup state should be the previous Step's end state where possible — don't force re-baselining.
- Group cases that share a common precondition together (e.g. all OOS variants in a row).
- Put regression checks (related but untouched flows) and defensive cases ("operator does the unexpected") at the end.

### No-skip rule

Every behavior the diff touches gets a Step. Steps cannot be skipped in Phase 2. You CAN merge two Steps if Step N's evidence already proves what Step N+1 was going to assert — but call it out explicitly to the user ("Steps 4 and 5 are the same assertion in different shapes; I'll fold them") rather than silently dropping. Default to keeping them separate.

### Temporary instrumentation rules

If you cannot verify something without instrumentation (e.g., a stub that's invoked but produces no observable side effect), you may add temporary instrumentation BUT it must be observability-only:

- ALLOWED: `print()`, `console.log()`, `logger.info()`, structured log lines, file-write of input args, anything that emits without changing branch behavior.
- FORBIDDEN: mocks, stubs that return different values, test-mode flags, branch-changing config, fixture data inserted into shared state.

Mark every instrumentation site with a comment like `# TEMPORARY (manual-qa - remove in Phase 3)` so Phase 3 can find them by grep.

### Print the procedure and stop

Once you've drafted Setup + all Steps + Cleanup checklist, print it to the user in full. Don't start Phase 2 until they confirm. They usually signal go by saying "go", "looks good", or just driving Step 1 — but if they push back on any Step, revise before starting.

## Phase 2 — Walk through together

Loop through each Step in order. For each:

1. Briefly reprint the Step (1-2 sentences of "What you do" + a one-liner of what you'll be checking). Don't re-print the full body — they have the procedure.
2. Wait for the done signal. The user usually says "done" but anything that signals readiness counts ("yes", "ok", "complete", a screenshot, etc.).
3. Run your checks (DB query, log grep, network read, file inspection).
4. Report PASS or FAIL with the actual evidence (rowcount, log line, etc.). On PASS use a brief ✅ summary. On FAIL, surface the discrepancy plainly.
5. Update todos: mark this Step done, mark the next Step in_progress.
6. Move to the next Step.

### Driver/observer split

The user drives the UI because they're faster at it. You drive the verification commands (Bash queries, log reads, file inspection). Don't ask the user to run shell commands or query the DB — that's your job. Don't try to drive the UI yourself unless they explicitly ask.

### When you can't verify

If the user says "done" but you have no way to confirm (forgot to capture a baseline, log rotated too fast, DB credential issue), say so plainly and ask for a different signal — don't fake-pass. If the verification gap is fundamental (e.g., the change has no observable backend effect at all), it shouldn't have been a Step in the first place — call that out.

### Failure handling

When a Step fails:

- **Small fix (≲ 15 min, no design work, no new requirements)** — fix inline. After the fix:
  - Determine which already-passed Steps could be invalidated by the fix. Be conservative — if in doubt, redo it.
  - Redo those Steps before proceeding to the next new Step.
- **Bigger fix (substantial code change, design rework, requirements clarification)** — STOP the QA. Tell the user the QA is being suspended, summarize what you found, propose the fix path. Once the fix lands, restart the entire QA from Phase 1 (the diff has changed; the procedure may need updating).
- **The user can override either default** — if they say "keep going, we'll fix later" or "let's stop now", do that.

When in doubt about which side of the threshold you're on, ask: "This looks like ~30 min of work. Want me to fix inline and re-run from Step X, or stop the QA and restart later?"

### When a Step becomes impossible

If a change made mid-QA (an inline fix, a config tweak) makes a later Step truly impossible or completely irrelevant — not just redundant but no-longer-applicable — call it out, say why, and skip with explicit user acknowledgment. Do NOT skip silently.

## Phase 3 — Cleanup (always runs)

Run this at the end, even if Phase 2 had to stop early.

1. Remove all temporary instrumentation. Grep for the marker you used (e.g. `TEMPORARY (manual-qa`) to find every site.
2. Restart any services that picked up instrumentation (`docker restart <container>`, dev-server reload, etc.) so the running app reflects the cleaned code.
3. Re-run the project's automated test suite (`uv run pytest`, `npm test`, project-specific). Report the result.
4. Final `git diff` review with the user — confirm the only changes are the intended ones (no leftover instrumentation, no debug prints, no stray files added during instrumentation).
5. List remaining work that came up during QA but didn't fit the current scope (follow-up tasks, broader bugs you noticed). Offer to spawn separate tasks for them.

## Format reminders

- Use clear headers in the printed procedure: `### Setup`, `### Step N — <one-line label>`, `### Cleanup`. Markdown headers, not bold lines, so the user can navigate by scrolling.
- For each Step in Phase 1's printed procedure, structure the body as:
  ```
  ### Step N — <one-line label>
  **What you do:** <1-3 sentences>
  **Expected (UI):** <observable signal>
  **My checks:** <bulleted list>
  ```
- In Phase 2, brevity matters: "**Step 4** — submit hardness 60. I'll check the DB and log for a new OOS row." That's enough.
- Use TodoWrite to track Phase progress and per-Step completion. Pick whichever granularity stays under ~15 todos: one per Phase plus one per Step usually works.
- Vocabulary: the top-level units in this command are **Phases** (1, 2, 3); inside Phase 2 the QA procedure has **Steps**. Don't introduce a third nested level — if a Step is too big, split it into Step Na / Step Nb.
