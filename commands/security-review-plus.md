---
allowed-tools: Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(git show:*), Bash(git remote show:*), Read, Glob, Grep, LS, Task
description: Wraps /security-review with an extra pass against the curated security-tips checklist
---

You are running a two-pass security review of the changes on this branch. Pass A is the built-in `/security-review` (delegated to a subagent so we always pick up the latest version). Pass B is a checklist walk against a curated tips file. Output one unified markdown report.

## Step 1: Load the curated tips checklist

Read `/Users/diego/.claude/memory/security-tips-srees.md` in full. Each entry has a **detection heuristic**, you will apply every one of them in Pass B. If the file cannot be read, abort with a clear error, do not silently skip Pass B.

## Step 2: Delegate Pass A to a subagent

Use the `Task` tool to spawn a `general-purpose` subagent with this prompt (verbatim):

> Run the `/security-review` skill on the current branch via the Skill tool. Return the skill's complete markdown report as your final message, with no preamble, no commentary, no wrapping. If the skill produces "no findings," return exactly that.

This isolates Pass A in the subagent's turn so the built-in skill's "end of turn" semantics don't terminate this command. When the subagent returns, capture its markdown output as the Pass A section of your report.

Do NOT replicate the built-in skill's logic here. The whole point of delegating is to pick up upstream improvements automatically.

## Step 3: Pass B, curated tips checklist

Gather the diff yourself for Pass B (the subagent worked on the same branch but its context is gone):

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

Reporting rules for Pass B:
- Confidence >= 8 to report (same bar as the built-in `/security-review`).
- Severity HIGH for direct exploit, MEDIUM for conditional, LOW for defense-in-depth (rarely worth reporting).
- Before recommending the stored solution, **briefly evaluate whether it still applies**. The tips file may be months old, frameworks and APIs change. If the stored solution looks stale or wrong for this stack, propose an updated fix and note the divergence.
- If the matching tip entry is marked `Needs solution`, flag the match but state that the solution must be derived, then propose one.

## Step 4: Combined report

Output a single markdown report. No preamble, no trailing summary, just the findings.

Structure:

```markdown
# Security Review

## Pass A: /security-review (built-in)

<paste the subagent's markdown verbatim, or "No findings." if it returned that>

## Pass B: Curated tips checklist

### Vuln B1: <tip title>: `path/to/file.ext:LINE`
- Tip: exact title from the tips file
- Tip source: URL from the tips entry
- Severity: HIGH | MEDIUM | LOW
- Confidence: N/10
- Description: how this code matches the tip's heuristic.
- Exploit scenario: concrete attack path.
- Recommendation: specific fix. If you adapted the stored solution, say so and explain why.

(repeat per finding, or write "No findings." if Pass B produced none)

## Coverage note (Pass B only)

One sentence per tip entry that you checked but did not flag, in the form: `- <tip title>: not applicable / no match in diff`. This is the audit trail proving every entry was actually checked, do not skip it.
```

Final reply: the markdown report and nothing else.
