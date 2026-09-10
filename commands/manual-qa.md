Generate a manual QA procedure from this session's changes and walk through it interactively. Applies to any change with a user interface, graphical or not: a web or desktop GUI, an HTTP API, a CLI command, or any other surface a person or a client program operates. Phase 0 makes sure the code under test is what's actually being exercised (critical when the session works in an isolated agent environment), then five phases: build the procedure, walk the happy paths, deliberately try to break things, triage what broke and fix what's worth fixing, clean up.

## When NOT to use

Decline only when the change has no interface at all, meaning nothing in the diff is operated by a person or a client program: an internal refactor with no behavior change, library code with no consumer exercised by this diff, build/CI/tooling config, a dependency bump. Tell the user manual QA is for end-to-end behavior at a surface someone actually uses, and these changes are better validated by the project's automated test suite.

How to detect: scan the diff for interface-touching files and classify each surface it touches.

- **GUI**: templates, components (JSX/TSX/Vue/Svelte/Blade/Livewire), HTML, layouts, route handlers that render, CSS that affects user-visible behavior.
- **API**: route/controller/handler definitions, request validation, serializers, OpenAPI or GraphQL schemas, webhooks, auth middleware.
- **CLI**: command definitions, argument parsers, `bin/` entries, console kernels, scripts meant to be run by hand.
- **Other user-facing output**: emails, notifications, exports and generated files, jobs a user triggers and sees the result of.

A change often spans more than one surface (an endpoint plus the screen that calls it, a command plus the scheduled job that wraps it). QA every surface the diff touches, not just the most visible one.

## Phase 0: Serve the code under test (isolated environments)

Before drafting the procedure, make sure that whatever gets exercised (a browser, curl, a command) is actually running THIS session's code. This matters most when the session works in an isolated agent environment: the user's normally-running app and their globally installed tools serve the main checkout, not your branch.

**Detect an isolated environment.** You're in one if `git rev-parse --git-dir` and `git rev-parse --git-common-dir` differ (linked worktree rather than main checkout), or the cwd sits under an env directory (e.g. `.claude/worktrees/`), or an env marker file like `.agent-env.json` exists. If you're in the main checkout, just confirm the dev server (or the CLI build) is running current code and move on to Phase 1.

**Discover the serving mechanism, never guess it.** This command is used across projects with different stacks, so the mechanism is always project-specific. Check in priority order:

1. **Project CLAUDE.md / project memory**: look for an agent-environments, QA, or takeover section that names the exact command for serving an env for manual testing. Follow it verbatim; those sections exist because the obvious approach has a known trap in that project.
2. **A provisioning-script convention**: an env tool the repo ships (e.g. `scripts/agent-env.sh` with a `serve` subcommand, or npm/make wrappers around it). Use its serve command rather than composing your own.
3. **Fallback**: run the project's normal dev command from inside the env directory, then hand the user the exact URL. If ports collide with the main checkout's servers, apply the canonical-address rule below.

**Canonical-address rule.** Decide whether the client can reach the app at any address or only a fixed one:

- **Fixed address** (Office add-in manifests, installed PWAs, OAuth redirect URIs, webhook receivers, hosts-file domains): the env must be served at that canonical address, which usually means displacing the main checkout's dev server. If you started that server yourself this session, stop it. If the user owns it (their terminal), ask them to stop it; don't kill their foreground processes unprompted. Either way, record "restore the main dev server" in the Cleanup checklist.
- **Any address**: serve on the env's own ports and put the exact URL in the procedure's Setup section.

**CLIs.** Invoke the env's own entry point (`./bin/<tool>`, `node dist/cli.js`, `php artisan` run from inside the env directory, the package's `npm run`/`uv run` wrapper), never a globally installed copy: the global one points at the main checkout or a published release. If the tool has to be installed to be tested (`npm link`, an editable pip install), do it and record the undo in the Cleanup checklist.

Whatever Phase 0 starts, stops, installs or displaces goes into Phase 1's Setup (so the user knows the state) and the Cleanup checklist (so it gets restored).

## Phase 1: Build the QA procedure

Inputs to consider:
- `git status --short` (untracked, modified, staged)
- `git diff <base>...HEAD` where `<base>` is the project's main branch (check CLAUDE.md, default to `main`)
- Conversation history for any decisions, reverts, or pivots that aren't visible in the final diff

Project-specific context. Ask the user before drafting if you're unsure about any of these:
- Which surface(s) to test and how to reach each one: URL, app or route for a GUI; base URL and auth method for an API; the exact invocation for a CLI (Phase 0)
- Which logs to tail (container, file, service)
- Which DB to query (engine, connection details, schema)
- Which credentials / badges / test accounts are safe to use

### Enumerate the happy paths

There is usually more than one. A happy path is a distinct, valid way a user accomplishes what the change enables. List them before writing Steps:

- each entry point or surface (the screen and the endpoint behind it, the command and the job that wraps it)
- each role or permission level that can legitimately do it
- each valid variant of the input: with and without optional fields, each supported format, each branch of a type or mode field, empty-but-valid states such as a first record or an empty list
- each valid outcome the change is supposed to produce (created vs updated, immediate vs queued, success vs a legitimate "nothing to do")

Every happy path gets at least one Step. If the list gets long, say which paths are primary and which are variants, but don't drop variants silently.

### Design the break-it Steps

Break-it Steps do things users normally wouldn't, on purpose, to find where the change falls over. Draft them here so the user reviews them with the rest of the procedure; Phase 3 extends them with whatever the happy-path run reveals. Pull from these categories, picking what's plausible for the surface:

- **Input abuse**: empty, whitespace-only, very long, unicode/emoji/RTL, leading and trailing spaces, HTML/script/SQL-looking strings, wrong type (a string where a number goes), boundaries (0, -1, max+1, far-future or far-past dates), a duplicate of something that should be unique.
- **Sequence abuse**: submit twice fast (double-click, replayed request, command run twice), skip a required step, do steps out of order, interrupt halfway (back button, refresh, Ctrl-C, dropped connection), act on stale data (two tabs, an old response).
- **State and permission abuse**: act on a record that is deleted, archived or someone else's (edit the ID), as the wrong role, with a missing or expired session or token, with a dependency absent (no rows yet, config unset).
- **GUI-specific**: back or refresh mid-flow, a narrow viewport, keyboard-only submit, browser autofill, pasted garbage, the same form open in a second tab.
- **API-specific**: wrong HTTP method, missing, extra or misspelled fields, wrong content-type, malformed JSON, unauthenticated and wrong-user requests, invalid IDs (0, negative, huge, a string, another resource's ID), oversized payload, pagination edges, the same request replayed.
- **CLI-specific**: no args, unknown flag, missing, unreadable or empty input file, paths with spaces or unicode, stdin instead of a file, piped or non-TTY invocation, a different cwd, a missing env var, Ctrl-C mid-run, the same run twice (idempotency). Check the exit code every time.

Lead with what a real user could hit by accident (double-submit, refresh, a typo in an ID, an empty field), then the deliberately hostile cases. Five to ten well-chosen break-it Steps beat thirty mechanical ones.

### Procedure structure

The procedure has four named sections you'll print verbatim to the user, then walk through in Phases 2 and 3:

**Setup**: anything to do before Step 1. Capture baselines (DB row counts, log line numbers, recent commits), bring up services, open log tails, surface the exact URL, base URL and auth header, or command form for each surface, and say who drives each surface (Phase 2, "Who drives"). Anything that gives "before" numbers so deltas are unambiguous.

**Happy paths**: Steps 1..N, covering every happy path and every behavior the diff changes.

**Break it**: Steps N+1..M, numbered continuously after the happy paths.

**Cleanup**: the closing checklist Phase 5 will run.

Each Step's printed body has three labeled parts:
- **What you do** or **What I do**, labeled by whoever drives this Step: 1-3 sentences, concrete actions with exact values (what to type, the exact request as method, path and body, the exact command line).
- **Expected (interface)**: what the driver observes at the surface: screen state (alert text, a modal opening, a chart point appearing), HTTP status and response shape, exit code plus stdout/stderr. For a break-it Step this states the *desired* behavior (a clear validation message, a 422 with a reason, exit 1 with a helpful line), not a prediction of what the code will do.
- **My checks**: the backend signals you'll verify: DB rowcount delta, log line, network request, file existence, queued job. For a break-it Step this always includes "no unintended state change": a rejected input wrote nothing, an interrupted flow left no orphan rows.

### Step ordering principles

- Simplest happy path first, so the user gets confidence the wiring is right before variants and edge cases.
- Each Step's setup state should be the previous Step's end state where possible. Don't force re-baselining.
- Group cases that share a common precondition together (e.g. all OOS variants in a row).
- Regression checks (related but untouched flows) close out the happy paths.
- Break-it Steps come after every happy path, most-plausible-accident first.

### No-skip rule

Every behavior the diff touches gets a Step, and every break-it Step you drafted gets run. Steps cannot be skipped in Phases 2 and 3. You CAN merge two Steps if Step N's evidence already proves what Step N+1 was going to assert, but call it out explicitly to the user ("Steps 4 and 5 are the same assertion in different shapes; I'll fold them") rather than silently dropping. Default to keeping them separate.

### Temporary instrumentation rules

If you cannot verify something without instrumentation (e.g., a stub that's invoked but produces no observable side effect), you may add temporary instrumentation BUT it must be observability-only:

- ALLOWED: `print()`, `console.log()`, `logger.info()`, structured log lines, file-write of input args, anything that emits without changing branch behavior.
- FORBIDDEN: mocks, stubs that return different values, test-mode flags, branch-changing config, fixture data inserted into shared state.

Mark every instrumentation site with a comment like `# TEMPORARY (manual-qa - remove in Phase 5)` so Phase 5 can find them by grep.

### Print the procedure and stop

Once you've drafted Setup + all Steps + Cleanup checklist, print it to the user in full. Don't start Phase 2 until they confirm. They usually signal go by saying "go", "looks good", or just driving Step 1, but if they push back on any Step, revise before starting.

## Phase 2: Happy paths

### Who drives

You drive, headlessly, by default:

- **API**: you, with curl or the project's own client, from inside the env.
- **CLI**: you, via Bash from inside the env, using the entry point Phase 0 settled on.
- **GUI**: you, with a throwaway Playwright script when a headless browser is installed (keep it in the env's gitignored tmp/ or the scratchpad, never commit it). Prefer the script over the Browser pane or Claude-in-Chrome for a full pass; they're too slow for many Steps, though fine for a single visual check.

Hand a Step to the user only when it cannot be done headlessly: the surface renders inside a host app (an Outlook add-in, an IDE, a mobile shell) or needs a real device, or it needs their terminal, session or credentials you must not handle. A project CLAUDE.md or the user can also pin a surface as user-driven. Mixed procedures are normal: label each Step with whoever drives it.

Verification is always yours. Don't ask the user to run shell commands or query the DB.

### Step loop

Loop through each happy-path Step in order. For each:

1. Briefly reprint the Step (1-2 sentences of the action plus a one-liner of what you'll check). Don't re-print the full body; they have the procedure.
2. Perform or wait:
   - **You drive**: run the action and capture the interface response (status and body, exit code and output, page state or screenshot). Run consecutive self-driven Steps back-to-back, reporting each; don't pause for a go-ahead between them.
   - **User drives**: wait for the done signal. The user usually says "done" but anything that signals readiness counts ("yes", "ok", "complete", a screenshot, etc.).
3. Run your checks (DB query, log grep, network read, file inspection).
4. Report PASS or FAIL with the actual evidence (rowcount, log line, response body). On PASS use a brief ✅ summary. On FAIL, surface the discrepancy plainly.
5. Update todos: mark this Step done, mark the next Step in_progress.
6. Move to the next Step.

**Trust a harness only once it has passed something.** A FAIL produced by a script or request you wrote can be a harness bug: a wrong selector, a missing cookie, a guessed coordinate, a 302 that looked like success. Before reporting FAIL on a self-driven Step, confirm the same harness passes a known-good case, and read stored state back rather than trusting a redirect or a 200.

### When you can't verify

If the Step is done but you have no way to confirm (forgot to capture a baseline, log rotated too fast, DB credential issue), say so plainly and find a different signal; don't fake-pass. If the verification gap is fundamental (e.g., the change has no observable backend effect at all), it shouldn't have been a Step in the first place; call that out.

### Failure handling

A happy-path FAIL is a bug in the feature, so it gets fixed here rather than deferred to Phase 4:

- **Small fix (≲ 15 min, no design work, no new requirements)**: fix inline. After the fix:
  - Determine which already-passed Steps could be invalidated by the fix. Be conservative; if in doubt, redo it.
  - Redo those Steps before proceeding to the next new Step.
- **Bigger fix (substantial code change, design rework, requirements clarification)**: STOP the QA. Tell the user the QA is being suspended, summarize what you found, propose the fix path. Once the fix lands, restart the entire QA from Phase 1 (the diff has changed; the procedure may need updating).
- **The user can override either default**: if they say "keep going, we'll fix later" or "let's stop now", do that.

When in doubt about which side of the threshold you're on, ask: "This looks like ~30 min of work. Want me to fix inline and re-run from Step X, or stop the QA and restart later?"

### When a Step becomes impossible

If a change made mid-QA (an inline fix, a config tweak) makes a later Step truly impossible or completely irrelevant (not just redundant but no-longer-applicable), call it out, say why, and skip with explicit user acknowledgment. Do NOT skip silently.

## Phase 3: Break it

Now do things users normally wouldn't, on purpose. Run the break-it Steps with the same loop as Phase 2, with these differences.

**Extend the list first.** The happy-path run will have shown you things the diff didn't: a field with no visible validation, an action with no confirmation, an ID taken straight from the URL. Add break-it Steps for those, print the additions (one line each), and go on a brief "go". Don't re-confirm the whole procedure.

**Record, don't fix.** A break-it Step that fails is a finding, not an emergency. Log it and keep going; Phase 4 decides what's worth fixing, and fixing here would mean re-running everything after each fix instead of once. Two exceptions: if a break leaves the environment unable to continue (a corrupt row, a wedged service), restore the state, note how, and make that part of the finding; and if a finding looks severe (data loss, another user's data exposed), say so the moment you see it so the user isn't surprised at triage, but still hold the fix for Phase 4 unless they say otherwise.

**A rejection is only a PASS if it's clean.** A 422, a validation message or a non-zero exit passes only when nothing changed underneath: check the DB and logs exactly as you would for a happy path. A stack trace shown to the user, a 500, or a rejected request that still wrote a row is a FAIL even though "it didn't crash".

### What counts as broken

Any of: a crash or raw error exposed to the user (500, stack trace, uncaught exception text); a silently wrong result (bad input accepted, the wrong record updated, a computation off); corrupted, orphaned or duplicated data; a stuck state that needs manual intervention to leave; acting on data the actor shouldn't reach (another user's record, a missing permission check); user input rendered back unescaped; a mismatch between what the surface shows and what the DB holds. An unhelpful but safe error (an unclear 400, a bare "error") is a finding too, just a low-consequence one.

### Recording findings

Keep a numbered findings list as you go. For each finding: the Step; exactly what you did (the input, the request, the command); what happened, with evidence; what a real user would experience; how it recovers (clears on refresh or retry, needs manual cleanup, data is lost); and whether this diff introduced it or it was already there (check the base branch when that's cheap, otherwise reason from the diff and say so). Print the full list at the end of Phase 3.

## Phase 4: Triage and fix

Decide, per finding, whether it's worth fixing now. Effort goes where the payback is: something a user could plausibly do by mistake with real consequences gets fixed; something that takes deliberate contortion to reach and clears on refresh doesn't.

### Verdicts

Judge each finding on three things:

- **Likelihood**: could a real user get here by accident (a typo, a double-click, the back button, a stale tab, unusual but legitimate data), or does it take deliberate effort?
- **Consequence**: data loss or corruption, a wrong result presented as right, a stuck state, security or privacy exposure, leaked internals; versus cosmetic, or an unclear but safe error.
- **Effort**: a guard or a validation rule, versus design work.

Then assign one of:

- **Fix now**: plausible by accident AND real consequences. Also fix now when the consequence is severe even if unlikely (security, data loss, another user's data), or when the fix is trivial and sits in code this change already touches, whatever the likelihood.
- **Follow-up**: real but out of scope, mainly pre-existing bugs this diff didn't introduce and improvements that need design work. These go to Phase 5's list of remaining work.
- **Won't fix**: takes deliberate contortion AND recovers cleanly (clear error, refresh or retry resets it, nothing written). Say so explicitly with the reason rather than leaving it off the list.
- **Ask**: whenever the call isn't obvious. Batch the Ask items into one question with your recommended verdict for each; don't ask one at a time.

Print the triage as a table: finding, likelihood, consequence, effort, verdict, one-line reason. Wait for the user to confirm before fixing; they'll usually approve as-is or tweak a verdict or two.

### Fixing

- The Phase 2 size threshold applies: small fixes inline; a fix that turns into design rework or new requirements suspends the QA, and the QA restarts from Phase 1 once it lands.
- Where the project has an automated suite, lock each fix in with a regression test at the right layer (unit or feature test first; a browser test only for browser-only behavior). The QA procedure is throwaway; the bug it caught shouldn't be.
- After the fixes, re-run each fixed finding's own Step to prove the fix, then every Step the fixes could have invalidated, happy-path and break-it alike. Be conservative: if in doubt, redo it.

## Phase 5: Cleanup (always runs)

Run this at the end, even if an earlier phase had to stop early.

1. Remove all temporary instrumentation. Grep for the marker you used (e.g. `TEMPORARY (manual-qa`) to find every site. Delete throwaway harness scripts unless they live somewhere gitignored and the user wants them kept.
2. Restart any services that picked up instrumentation (`docker restart <container>`, dev-server reload, etc.) so the running app reflects the cleaned code.
3. Re-run the project's automated test suite (`uv run pytest`, `npm test`, project-specific). Report the result.
4. Final `git diff` review with the user: confirm the only changes are the intended ones plus Phase 4's fixes and their tests (no leftover instrumentation, no debug prints, no stray files).
5. Undo Phase 0's environment changes: stop the env's servers if the user is done, unlink or uninstall a CLI you installed for the test, and if the main checkout's dev server was stopped or displaced for the QA, remind the user to restart it (or restart it yourself if you started it this session).
6. List remaining work that came up during QA but didn't fit the current scope: Phase 4's Follow-up verdicts, broader bugs you noticed. Offer to spawn separate tasks for them.
7. Close with a summary that stands on its own without the transcript: happy-path results, the findings table with verdicts, what was fixed and re-verified, what's deferred. Findings reported only between tool calls tend to go unread.

## Format reminders

- Use markdown headers in the printed procedure, not bold lines, so the user can navigate by scrolling: `## Setup`, `## Happy paths`, `## Break it`, `## Cleanup` for the sections, and `### Step N: <one-line label>` for every Step under the two Step sections.
- Structure each Step's body in Phase 1's printed procedure as:
  ```
  ### Step N: <one-line label>
  **What you do:** <1-3 sentences>        (or **What I do:** when you drive)
  **Expected (interface):** <observable signal at the surface>
  **My checks:** <bulleted list>
  ```
- In Phases 2 and 3, brevity matters: "**Step 4**: submit hardness 60. I'll check the DB and log for a new OOS row." That's enough.
- Use TodoWrite to track progress: one todo per Phase, plus one per Step of the Phase currently running. Keep it under ~15 at a time.
- Vocabulary: the top-level units in this command are **Phases** (0-5). Inside Phases 2 and 3 the procedure has **Steps**. Break-it Steps that fail produce **Findings**; Phase 4 gives each a **Verdict**. Don't introduce another nested level: if a Step is too big, split it into Step Na / Step Nb.
- **Confirmation pauses in autonomous runs.** When this command runs inside a workflow the user has already authorized to run without stopping (the agent-environments pre-PR workflow), don't pause for the procedure confirmation or the triage confirmation: proceed with your recommended verdicts, fix the Fix-now items, and carry every Ask and Won't-fix verdict into the final report so the user can overrule.
