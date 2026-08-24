---
name: security-review-plus
description: Wraps /security-review with a curated checklist pass, plus a Checkpoint whole-app scan on Laravel projects
allowed-tools: Bash(git diff:*), Bash(git status:*), Bash(git -C:*), Bash(git log:*), Bash(git show:*), Bash(git remote show:*), Bash(git add composer.json composer.lock), Bash(git commit:*), Bash(php artisan checkpoint:scan:*), Bash(/opt/homebrew/bin/php artisan checkpoint:scan:*), Bash(composer require:*), Bash(/opt/homebrew/bin/composer require:*), Read, Glob, Grep, LS, Task, AskUserQuestion, Write
---

You are running a three-phase security review. Phase 1 is the built-in `/security-review` (delegated to a subagent so we always pick up the latest version). Phase 2 is a checklist walk against the curated tips file bundled with this skill. Phase 3 is a Checkpoint whole-application scan, Laravel projects only. Output one unified markdown report.

## Step 1: Load the curated tips checklist

Read `security-tips.md` from this skill's directory (the same directory this SKILL.md was loaded from) in full. Each entry has a **detection heuristic**, you will apply every one of them in Phase 2. If the file cannot be read, abort with a clear error, do not silently skip Phase 2.

## Step 2: Resolve the target checkout and gate on a non-empty diff

The review targets a checkout, not the session. Default `<target>` to the session cwd, but if the arguments or the conversation name a different worktree (an agent env, a `git worktree` path), that absolute path is `<target>`. Substitute it literally in every command below.

Resolve `<base>` and confirm there is something to review:

```
git -C <target> diff --shortstat origin/HEAD...
git -C <target> diff --shortstat main...HEAD
```

`<base>` is `origin/HEAD` if the first command succeeds with a non-empty stat, otherwise `main`. If BOTH are empty or fail, **abort the entire review with an error** naming `<target>` and its current branch (`git -C <target> branch --show-current`). Do not run any phase and do not output "No findings." An empty diff at review time almost always means the wrong checkout (typically the session sitting in the main checkout while the branch lives in a worktree), and a clean report over zero reviewed lines reads as a clean bill of health. If the work lives in an agent-env worktree, rerun with that worktree as `<target>`.

## Step 3: Phase 1, delegate to a subagent

Use the `Task` tool to spawn a `general-purpose` subagent with this prompt, substituting `<target>` and `<base>` (otherwise verbatim):

> cd into `<target>` and confirm `git branch --show-current` prints the branch under review. Then run the `/security-review` skill via the Skill tool. Cross-check the result: if the skill reports no changes, an empty diff, or a clean tree while `git -C <target> diff <base>...HEAD` is non-empty, return exactly `PHASE 1 SAW AN EMPTY DIFF` and nothing else. Otherwise return the skill's complete markdown report as your final message, with no preamble, no commentary, no wrapping. If the skill produces "no findings" against the real diff, return exactly that.

This isolates Phase 1 in the subagent's turn so the built-in skill's "end of turn" semantics don't terminate this command. When the subagent returns, capture its markdown output as the Phase 1 section of your report. If it returns `PHASE 1 SAW AN EMPTY DIFF`, record Phase 1 in the report as failed to run (the built-in skill pre-gathers its diff from the session cwd, so it read the wrong checkout). Never present that as a clean pass. Phases 2 and 3 still proceed; they gather their own diff with `git -C <target>`.

Do NOT replicate the built-in skill's logic here. The whole point of delegating is to pick up upstream improvements automatically.

## Step 4: Phase 2, curated tips checklist

Gather the diff yourself for Phase 2 (the subagent worked on the same branch but its context is gone). Run both of these now, with the `<target>` and `<base>` resolved in Step 2:

```
git -C <target> diff --name-only <base>...
git -C <target> diff <base>...
```

For **every entry** in the tips file loaded in Step 1, apply its detection heuristic. Do not skip entries because they look Laravel-specific, the underlying principle often applies elsewhere (the file marks Scope on each entry, use that as guidance, not an excuse to skip).

Scope of search per entry:
- **Primary:** the diff. New code introducing the pattern is always reportable.
- **Secondary:** the broader codebase, but only when the heuristic explicitly demands it (e.g. for "validate config at boot," check whether a service provider asserts the required config, not just the diff). Note in the finding when you went beyond the diff.

Reporting rules for Phase 2:
- Confidence >= 8 to report (same bar as the built-in `/security-review`).
- Severity HIGH for direct exploit, MEDIUM for conditional, LOW for defense-in-depth (rarely worth reporting).
- Before recommending the stored solution, **briefly evaluate whether it still applies**. The tips file may be months old, frameworks and APIs change. If the stored solution looks stale or wrong for this stack, propose an updated fix and note the divergence.
- If the matching tip entry is marked `Needs solution`, flag the match but state that the solution must be derived, then propose one.

## Step 5: Phase 3, Checkpoint scan (Laravel only)

Checkpoint (https://github.com/andreapollastri/checkpoint) is a Laravel security scanner run via `php artisan checkpoint:scan`. Unlike Phases 1 and 2, it audits the **entire application**, not the branch diff. Run this phase only after Phases 1 and 2 have gathered their diffs, so an install here cannot contaminate them.

Work through these gates in order. The first gate that fails ends the phase with a one-line skip reason in the report.

1. **Laravel check.** Read `composer.json` in `<target>`. If `laravel/framework` is not in `require`, report `Phase 3 skipped: not a Laravel project.` and stop here.
2. **Opt-out check.** If the file `.claude/skip-checkpoint` exists in `<target>`, report `Phase 3 skipped: opt-out marker present (.claude/skip-checkpoint).` and stop here.
3. **Installed check.** If `andreapollastri/checkpoint` is in `require-dev`, run the scan (see below). If the artisan command turns out to be missing despite the composer.json entry, `vendor/` is stale: report that and recommend the user run `composer install`, do not run it yourself.
4. **Not installed: requirements check.** From `composer.json`, verify the minimum requirements: the `require.php` constraint must permit some PHP >= 8.1, and the `laravel/framework` constraint must fall within major versions 8 through 13. If not met, report `Phase 3 skipped: Checkpoint requirements not met (<specific reason>).` and stop here.
5. **Not installed, requirements met: ask the user.** Use `AskUserQuestion` with these options:
   - **"Install and scan now (Recommended)"**: Run `composer require --dev andreapollastri/checkpoint`. Then, only if `composer.json` and `composer.lock` had no uncommitted changes before the install (check with `git status --porcelain` first), commit just those two files with a one-sentence message like `Add Checkpoint security scanner as dev dependency`. If they were already dirty before the install, do not commit, tell the user to sort the commit out themselves after the review. Either way, then run the scan.
   - **"I'll install it myself"**: Skip the scan. In the report, note that Phase 3 was skipped and include the install command (`composer require --dev andreapollastri/checkpoint`) so it runs next time.
   - **"Never for this project"**: Create `.claude/skip-checkpoint` in `<target>` with a single line of content explaining its purpose (e.g. `Presence of this file tells /security-review-plus to skip the Checkpoint scan phase for this project.`). Note in the report that future runs will skip Phase 3.

Running the scan:
- Command: `php artisan checkpoint:scan --json`, run from `<target>`
- The sandbox PATH is incomplete. If `php` or `composer` are not found, use `/opt/homebrew/bin/php` and `/opt/homebrew/bin/composer` instead.
- Exit code 1 means the scan found failures. That is a result, not an execution error.

Reporting rules for Phase 3:
- List **only** WARN and FAIL results, with the check name and the detail/remediation from the JSON output. Never enumerate passing checks.
- Include one summary line with the pass count, e.g. `41 of 52 checks passed.`
- The section must state up front that results cover the entire application, not just this branch's changes.

## Step 6: Combined report

Output a single markdown report. No preamble, no trailing summary, just the findings.

Structure:

```markdown
# Security Review

## Phase 1: /security-review (built-in)

<paste the subagent's markdown verbatim; "No findings." if it returned that; or, if it returned PHASE 1 SAW AN EMPTY DIFF: 'Phase 1 failed to run (the built-in skill read the wrong checkout); diff coverage continues in Phase 2.'>

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
