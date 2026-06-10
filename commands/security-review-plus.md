---
allowed-tools: Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(git show:*), Bash(git remote show:*), Bash(git add composer.json composer.lock), Bash(git commit:*), Bash(php artisan checkpoint:scan:*), Bash(/opt/homebrew/bin/php artisan checkpoint:scan:*), Bash(composer require:*), Bash(/opt/homebrew/bin/composer require:*), Read, Glob, Grep, LS, Task, AskUserQuestion, Write
description: Wraps /security-review with a curated checklist pass, plus a Checkpoint whole-app scan on Laravel projects
---

You are running a three-phase security review. Phase 1 is the built-in `/security-review` (delegated to a subagent so we always pick up the latest version). Phase 2 is a checklist walk against a curated tips file. Phase 3 is a Checkpoint whole-application scan, Laravel projects only. Output one unified markdown report.

## Step 1: Load the curated tips checklist

Read `/Users/diego/.claude/memory/security-tips-srees.md` in full. Each entry has a **detection heuristic**, you will apply every one of them in Phase 2. If the file cannot be read, abort with a clear error, do not silently skip Phase 2.

## Step 2: Phase 1, delegate to a subagent

Use the `Task` tool to spawn a `general-purpose` subagent with this prompt (verbatim):

> Run the `/security-review` skill on the current branch via the Skill tool. Return the skill's complete markdown report as your final message, with no preamble, no commentary, no wrapping. If the skill produces "no findings," return exactly that.

This isolates Phase 1 in the subagent's turn so the built-in skill's "end of turn" semantics don't terminate this command. When the subagent returns, capture its markdown output as the Phase 1 section of your report.

Do NOT replicate the built-in skill's logic here. The whole point of delegating is to pick up upstream improvements automatically.

## Step 3: Phase 2, curated tips checklist

Gather the diff yourself for Phase 2 (the subagent worked on the same branch but its context is gone):

```
!`git diff --name-only origin/HEAD...`
```

```
!`git diff origin/HEAD...`
```

If `origin/HEAD` is unset or the diff is empty, fall back to `main...HEAD`.

For **every entry** in the tips file loaded in Step 1, apply its detection heuristic. Do not skip entries because they look Laravel-specific, the underlying principle often applies elsewhere (the file marks Scope on each entry, use that as guidance, not an excuse to skip).

Scope of search per entry:
- **Primary:** the diff. New code introducing the pattern is always reportable.
- **Secondary:** the broader codebase, but only when the heuristic explicitly demands it (e.g. for "validate config at boot," check whether a service provider asserts the required config, not just the diff). Note in the finding when you went beyond the diff.

Reporting rules for Phase 2:
- Confidence >= 8 to report (same bar as the built-in `/security-review`).
- Severity HIGH for direct exploit, MEDIUM for conditional, LOW for defense-in-depth (rarely worth reporting).
- Before recommending the stored solution, **briefly evaluate whether it still applies**. The tips file may be months old, frameworks and APIs change. If the stored solution looks stale or wrong for this stack, propose an updated fix and note the divergence.
- If the matching tip entry is marked `Needs solution`, flag the match but state that the solution must be derived, then propose one.

## Step 4: Phase 3, Checkpoint scan (Laravel only)

Checkpoint (https://github.com/andreapollastri/checkpoint) is a Laravel security scanner run via `php artisan checkpoint:scan`. Unlike Phases 1 and 2, it audits the **entire application**, not the branch diff. Run this phase only after Phases 1 and 2 have gathered their diffs, so an install here cannot contaminate them.

Work through these gates in order. The first gate that fails ends the phase with a one-line skip reason in the report.

1. **Laravel check.** Read `composer.json` in the project root. If `laravel/framework` is not in `require`, report `Phase 3 skipped: not a Laravel project.` and stop here.
2. **Opt-out check.** If the file `.claude/skip-checkpoint` exists in the project root, report `Phase 3 skipped: opt-out marker present (.claude/skip-checkpoint).` and stop here.
3. **Installed check.** If `andreapollastri/checkpoint` is in `require-dev`, run the scan (see below). If the artisan command turns out to be missing despite the composer.json entry, `vendor/` is stale: report that and recommend the user run `composer install`, do not run it yourself.
4. **Not installed: requirements check.** From `composer.json`, verify the minimum requirements: the `require.php` constraint must permit some PHP >= 8.1, and the `laravel/framework` constraint must fall within major versions 8 through 13. If not met, report `Phase 3 skipped: Checkpoint requirements not met (<specific reason>).` and stop here.
5. **Not installed, requirements met: ask the user.** Use `AskUserQuestion` with these options:
   - **"Install and scan now (Recommended)"**: Run `composer require --dev andreapollastri/checkpoint`. Then, only if `composer.json` and `composer.lock` had no uncommitted changes before the install (check with `git status --porcelain` first), commit just those two files with a one-sentence message like `Add Checkpoint security scanner as dev dependency`. If they were already dirty before the install, do not commit, tell the user to sort the commit out themselves after the review. Either way, then run the scan.
   - **"I'll install it myself"**: Skip the scan. In the report, note that Phase 3 was skipped and include the install command (`composer require --dev andreapollastri/checkpoint`) so it runs next time.
   - **"Never for this project"**: Create `.claude/skip-checkpoint` in the project root with a single line of content explaining its purpose (e.g. `Presence of this file tells /security-review-plus to skip the Checkpoint scan phase for this project.`). Note in the report that future runs will skip Phase 3.

Running the scan:
- Command: `php artisan checkpoint:scan --json`
- The sandbox PATH is incomplete. If `php` or `composer` are not found, use `/opt/homebrew/bin/php` and `/opt/homebrew/bin/composer` instead.
- Exit code 1 means the scan found failures. That is a result, not an execution error.

Reporting rules for Phase 3:
- List **only** WARN and FAIL results, with the check name and the detail/remediation from the JSON output. Never enumerate passing checks.
- Include one summary line with the pass count, e.g. `41 of 52 checks passed.`
- The section must state up front that results cover the entire application, not just this branch's changes.

## Step 5: Combined report

Output a single markdown report. No preamble, no trailing summary, just the findings.

Structure:

```markdown
# Security Review

## Phase 1: /security-review (built-in)

<paste the subagent's markdown verbatim, or "No findings." if it returned that>

## Phase 2: Curated tips checklist

### Vuln B1: <tip title>: `path/to/file.ext:LINE`
- Tip: exact title from the tips file
- Tip source: URL from the tips entry
- Severity: HIGH | MEDIUM | LOW
- Confidence: N/10
- Description: how this code matches the tip's heuristic.
- Exploit scenario: concrete attack path.
- Recommendation: specific fix. If you adapted the stored solution, say so and explain why.

(repeat per finding, or write "No findings." if Phase 2 produced none)

## Phase 3: Checkpoint scan (whole application)

> Scope: these results cover the entire application, not just this branch's diff.

Summary: N of M checks passed.

### FAIL: <check name>
- Detail: what Checkpoint reported.
- Recommendation: remediation from the scan output, sanity-checked against the codebase.

### WARN: <check name>
- (same fields)

(or a single line: "Phase 3 skipped: <reason>.")

## Coverage note (Phase 2 only)

One sentence per tip entry that you checked but did not flag, in the form: `- <tip title>: not applicable / no match in diff`. This is the audit trail proving every entry was actually checked, do not skip it.
```

Final reply: the markdown report and nothing else.
