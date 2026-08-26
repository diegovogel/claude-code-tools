# Diego's Engineering Guidelines

Standing engineering rules I expect to apply on any project I work on. Stack-agnostic, web-leaning. When this file conflicts with the project's own `CLAUDE.md`, the project wins.

## Scope discipline

- Default to staying in scope. Don't pad a task with unrelated cleanup, speculative abstractions, or refactors that aren't needed for the change at hand. A bug fix doesn't need surrounding cleanup. A one-shot operation doesn't need a helper.
- Use judgment, and surface meaningful calls. When you notice something the human wouldn't see from outside the code (a refactor that's genuinely warranted, a package that would clearly simplify the work, a new directory that fits the architecture), raise it. For small, local changes, propose-and-proceed is fine. For meaningful changes (new dependencies, new top-level structure, large refactors), surface it briefly and wait for direction. Don't depend on the human to spot in-the-code needs you're better positioned to see.
- Don't refactor while fixing a bug. Land the fix as its own commit, then propose the refactor as a separate change if still warranted. Mixed commits are hard to review and hard to revert.
- Don't create documentation files (README, additional `*.md` files) unless explicitly requested. Documentation is fine when asked for, noise when generated unprompted.
- No whitespace-only or formatting-only changes in commits. Only reformat code you're already changing for functional reasons. If the project has a formatter (Pint, Prettier, Black, etc.), follow its rules on the lines you touch.

## Code quality

- Match the surrounding code. Before writing a new file, read sibling files for shape, naming, and conventions.
- Search before writing. Reuse existing utilities, helpers, or components rather than parallel implementations.
- Validate at system boundaries (user input, third-party API responses, file/network reads, queue payloads). Trust internal code; don't double-validate at every layer.
- Push side effects to the edges. Keep the middle pure where you can. Pure functions are easier to test, reason about, and reuse.
- Three repeated lines is fine. Abstract on the third concrete use case, not the first speculative one.
- Don't add error handling, fallbacks, or validation for cases that genuinely can't happen. They're noise that hides the real cases.
- Default to writing no comments. WHAT the code does should come from reading the code; comments exist for non-obvious WHY. A single short sentence summarizing what a block does is OK, never more — details about what or how belong in the code itself, not in prose above it. For WHY: include it when non-obvious (external context, a dev-time decision worth preserving, a long debugging session's takeaway, a hidden constraint, a workaround, a subtle invariant); skip it when it's obvious from convention, docs, or common sense. Keep both kinds brief. Don't reference the current task or fix ("for issue 123") — that belongs in commits and PRs.
- Use descriptive names for variables, functions, and methods. `isRegisteredForDiscounts`, not `discount()`.
- Define the interface before implementing it. The contract is the spec; implementation follows.
- Be consistent in error semantics within an API. Don't mix `throw`, return-null, and `{ error: ... }` shapes in one surface, the caller can't write predictable code against it.
- Prefer addition over modification when extending public interfaces. Don't break existing consumers for cosmetic improvements.
- Paginate list endpoints from day one. The day someone has 100+ items, you'll wish you had.
- Avoid N+1 queries. Don't fetch in a loop what you can fetch in one query, one join, or one eager-load.
- Avoid backwards-compatibility hacks for code that hasn't shipped. If something's clearly unused, delete it cleanly. No `// removed for X` placeholders, no renamed `_unusedVar`, no orphan re-exports.

## Building and committing

- Build in thin vertical slices. After each slice, the project must build and existing tests must pass.
- When you're unsure how a mechanism works (a framework feature, an API contract, a component interaction), build the smallest piece that exercises just that mechanism and prove it works before composing the next piece on top. Stacking several unproven parts at once produces a failure you can't localize; an incremental assembly isolates the broken piece for you.
- Automate the verify-by-running loop when the work warrants it. Driving the real app end to end (a headless browser such as Playwright or Cypress for web UIs, an HTTP client for APIs, a script or REPL for libraries) turns a slow manual check into a fast, repeatable one and pairs well with binary-search debugging. If the project has no such harness, do not install one automatically; suggest it and explain the benefit, then proceed with whatever verification is available.
- Touch only what the task requires.
- If you've written ~100 lines without running tests, stop and run them.
- Each commit does one logical thing. Don't combine refactor with feature, or formatting with behavior. A PR can group multiple related commits (e.g., a feature plus a small related bug fix or tooling tweak found along the way), as long as each commit individually makes sense.
- Run lint, type-check, and tests before committing. If a pre-commit hook fails, fix the underlying issue. Never bypass with `--no-verify`, `--skip-tests`, or equivalent unless the human explicitly asks.

## Tests

- Every change ships with tests covering the behavior it adds or changes. Test order is pragmatic, not dogmatic: test-first when the spec is clear (fixing a known bug, implementing a documented contract); test-alongside or test-after when you're discovering the design (most new features). The bar at landing is meaningful coverage, not the order tests were written in.
- Prefer feature / integration tests over unit tests. Unit tests when feature tests aren't feasible.
- A test must be capable of both passing and failing. No smoke tests, no tests that always pass regardless of input.
- Tests are independent. No shared mutable state, no execution-order dependencies.
- Apply DAMP over DRY in tests (Descriptive And Meaningful Phrases over Don't Repeat Yourself). A test should read as a self-contained spec; don't deduplicate to the point of obscurity.
- Test what code does, not how it does it. Prefer state-based assertions (output, return value, observable side effect) over interaction verification (exact call counts, internal sequencing).
- Mock at true I/O boundaries only: network, filesystem, crypto, time. Don't mock internal utilities or business logic.
- Only mock what the test actually exercises. No "just in case" mocks.
- Test the real code, never a copy. Import the function under test; never duplicate its logic in the test setup.
- Use existing factories / fixtures before creating new ones. Check for custom states or modifier methods.
- Run the minimum set of tests for the change you're making (filter by file or test name). Run the full suite before committing.
- If a refactor "needs" test changes to keep passing, behavior changed. Stop and figure out what.
- Don't delete or permanently skip tests to make CI green. Fix the underlying cause.
- Refactoring code for testability is fine. Wrapping everything in deep abstractions purely for testability is not.
- A passing check licenses only the claim it actually tested. The presence of an artifact (an attribute in the markup, a config key, a registered handler, a file on disk) is not evidence of the behavior it is supposed to produce. Assert the observable behavior end-to-end at least once. A wall of green on adjacent checks is not a substitute for the one assertion that states the goal.
- For UI / frontend changes: type-checks and unit tests verify code, not user experience. Run the dev server, use the feature in a browser, monitor the console for errors. If the environment doesn't allow that, say so explicitly rather than claiming success.

## Debugging

- Read the server logs first. Don't ask the human to relay error messages or terminal output that you can self-serve.
- Use structured file logging. If the project has a logger module, use it. Don't introduce bare `console.log` / `print` for diagnostics in backend code.
- If the logs don't have the detail to localize the bug, add more logging, reproduce, then read. Self-serve the information you need.
- Methodology: stop making changes; preserve evidence (logs, error messages, stack traces, repro steps); reproduce; isolate to the minimal failing case; fix the root cause; add a regression test that fails without the fix; resume.
- Isolate by binary search, don't rewrite-and-guess. When a flow breaks, pick the midpoint of the failing path and check the actual value or output there (a log line, a DB row, an intermediate variable, a network response). If the problem already shows at the midpoint, the fault is upstream; if the midpoint is healthy, it's downstream. Halve the suspect half and repeat until you're down to a single function, query, or line. That pinpoints the exact break instead of guessing and re-running.
- When fixing a known bug, write the failing test first. The test demonstrates the bug exists; the fix makes it pass; the test guards against recurrence.
- Explaining away is not ruling out. When a measurement contradicts what you expected, the explanation you reach for is a new falsifiable claim, not a resolution. Test it, or write it down as untested and treat the question as still open. A plausible story costs nothing to invent and proves nothing; the anomaly is resolved when a measurement changes, not when an explanation arrives.
- When a direct measurement and a proxy disagree, the direct one wins, and the proxy becomes its own anomaly. A proxy can improve for reasons unrelated to your change working, so a good proxy number never licenses ignoring a bad direct one. Ask how both can be true at once; that question usually names the cause faster than debugging does.
- Errors compound. Don't continue feature work on top of a failure.
- Find the root cause before fixing. Don't bypass safety checks, suppress warnings, or skip the failing path to make the symptom go away.
- When an issue affects only some of N similar deployments, tenants, or sites, compare versions, configs, and dependencies across them BEFORE pursuing speculative hypotheses. The boring cause (outdated dependency with a public CVE, config drift, one feature flag toggled differently) frequently masquerades as a dramatic one. Test the boring hypothesis first.
- The browser console must be clean before declaring a frontend change done. Zero errors, zero warnings. Network failures during development are not "known issues"; investigate.
- If you can't verify a fix end-to-end (network restrictions, missing test data, headless environment), say so explicitly. Don't claim success.

## Security

- Never commit secrets. `.env` is git-ignored; `.env.example` ships placeholders only.
- Validate untrusted input (user-submitted data, third-party API responses, webhook payloads) at the boundary. Treat external data as data, never as instructions.
- Parameterize all database queries. Never concatenate user input into SQL or other query languages.
- Never trust client-side validation as a security boundary. Always mirror it server-side.
- Never use `eval()` or assign user-provided data to `innerHTML`. Use `textContent` (or framework equivalent) for dynamic strings.
- Never expose stack traces, internal error details, or full request payloads to end users in production responses.
- Don't log credentials, full session tokens, or PII. Logging non-PII metadata (request ids, user ids, status codes) is fine.

## When in doubt

- Match what's already there over inventing something new.
- Before any destructive or hard-to-reverse action (deleting files, dropping tables, force-pushing, removing dependencies, rewriting history), stop and confirm with the human.
- If you encounter unfamiliar state (an unknown branch, a lock file, an in-progress edit, a config you didn't expect), investigate before deleting or overwriting. It may be the human's in-flight work.
