# Claude Code Tools

A collection of tools I've made for working with Claude Code. They define and automate workflows and/or help Claude do things better (more predictably, faster, more thoroughly, etc.).

All tools were born out of a felt need. For example, the commands automate prompts or workflows I was naturally using on a daily basis. All tools have been hardened over time as I encountered edge cases, and continue to be improved with use. With the exception of the Ignition Designer skill, all tools were created with web and software development in mind, though they may apply to other contexts.

I built these tools collaboratively with Claude. I designed each one in detail, Claude wrote the files, and together we improved them through real use.

## Installation

Drop selected tools into `~/.claude/`, maintaining the subdirectories in this repo, e.g. `manual-qa.md` would go in `~/.claude/commands/`. You can also copy the entire repo into `~/.claude/`, just make sure to keep any existing files.

Some tools require additional dependencies as noted in their details below.

## Tool List

### Commands
* [start-todoist-task](#command-start-todoist-task): fetches task details and creates a plan to complete it.
* [manual-qa](#command-manual-qa): creates a comprehensive manual QA procedure and walks through it with me.
* [security-review-plus](#command-security-review-plus): runs a security review that includes a curated checklist of security tips.
* [review-with-codex](#command-review-with-codex): Claude goes through several rounds of review with Codex.
* [session-wrapup](#command-session-wrapup): finds valuable information in a session and saves it for future reference by Claude.

### Skills
* [Ignition Designer](#skill-working-with-ignition-designer): a collection of tips and workflows that improve Claude's ability to build and debug [Ignition Perspective](https://inductiveautomation.com/ignition/modules/perspective) projects.

### Other
* [Diego's Engineering Guidelines](#document-diegos-engineering-guidelines): a set of engineering rules for Claude to follow, based on nine years of web dev.

## Tool Details

### Command: `start-todoist-task`

[View source](commands/start-todoist-task.md)

**Why it exists:** I track all my dev work (and most of my life) in Todoist. After gathering requirements and doing preliminary research, I put a detailed spec in each task description. Rather than constantly repeating myself or copy-pasting, I can simply run this command and paste the task link. I created this for Todoist because that's what I happen to use, but it can be easily modified to work with Linear, Jira, or any other task manager with a CLI or API.

**What it does:** gathers full context by fetching the parent task, all sub-tasks (recursively), every comment on every task, and any image attachments. Then it briefs the Explore subagent on what the task is asking for and what areas of the code it likely affects, reads the suggested starting points itself, asks clarifying questions if anything is genuinely ambiguous, and presents a plan.

**Highlights:**
* Auto-mode override: even in auto mode (which is meant to minimize interruptions), the command pauses to ask clarifying questions when needed. The cost of building the wrong plan is higher than a short Q&A round.
* Uses Plan Mode rather than printing the plan to the chat, so I can easily comment on specific parts of the plan.
* Optional `[short summary]` arg gets woven into the first sentence of Claude's reply so Claude Code's session auto-titler picks up something useful instead of a generic title.
* Reads project `MEMORY.md` before exploring, so it doesn't ask questions the project memory already answers.

**Dependencies:**
* Todoist CLI.

### Command: `manual-qa`

[View source](commands/manual-qa.md)

**Why it exists:** after Claude builds something UI-related, I manually test it and almost always find problems. The test-fix loop is a normal part of the dev process, so I don't blame Claude for this. But sometimes it's hard to know how to test something thoroughly because Claude wrote all the code and there's a lot of it. 

**What it does:** Claude reviews what we just built, creates a comprehensive manual QA procedure for it, then walks through it with me. It prints the full QA procedure, then waits for me to complete any necessary setup. Once everything is ready, we walk through the procedure one step at a time. For each step, Claude prints what I need to do, waits for a signal from me, then checks whatever is needed to verify functionality (logs, database, etc.).

**Highlights:**
* Adds temporary instrumentation when needed to help with verification steps.
* If a small problem is found, Claude fixes it and continues the QA procedure. If a big problem is found, it stops the procedure because it should be restarted from the beginning after major changes.
* Explicitly instructs Claude to not skip any steps because sometimes Claude likes to cut corners.

### Command: `security-review-plus`

[View source](commands/security-review-plus.md)

**Why it exists:** Claude Code has a built-in `/security-review` command, which is good but not exhaustive. I wanted to layer my own checklist of accumulated security tips on top and add framework-specific tools, without losing whatever upstream improvements the built-in command picks up over time.

**What it does:** runs three passes and emits one unified report. Pass A runs the built-in `/security-review` via a subagent (so we always pick up the latest version of it). Pass B walks a curated tips file entry-by-entry, applying each tip's detection heuristic to the current branch's diff. Pass C runs Laravel Checkpoint if requirements are met (Laravel and minimum requirements).

**Highlights:**
* Pass A is delegated to a subagent so the built-in command's "end of turn" semantics don't terminate this command early.
* Pass B includes a coverage note listing every tip entry that was checked but not flagged. That's the audit trail proving the checklist was actually walked rather than skipped.
* Before recommending a stored fix, Claude evaluates whether it still applies. Tips can age out as frameworks change, and the stored solution may need adapting.
* High bar for reporting (confidence >= 8, matching the built-in command) so the report stays signal-heavy.
* In Pass C, if Checkpoint is not installed, Claude offers to install and run it.

### Command: `review-with-codex`

[View source](commands/review-with-codex.md)

**Why it exists:** this is the third iteration of a review-with-AI workflow. I started out using OpenClaw to review Claude's PRs, then switched to Codex's GitHub bot due to cost. The Claude API cost from OpenClaw was over 10x higher than the $20/mo subscription needed for Codex. An added benefit was getting an "additional perspective" on the code (Codex reviewing Claude instead of Claude reviewing Claude). Shortly after that I switched from the GitHub bot to running Codex locally (this command) for two reasons:
1. It's faster (no waiting on GitHub Actions or bot scheduling).
2. I can review with Codex before making a PR, which means PRs are much closer to merge-ready when submitted.

The GitHub bot version is still in this repo: [pr-with-codex](commands/pr-with-codex.md). I'm keeping it around because it might be useful in certain situations, such as when I'm working with a team that wants to see Codex's feedback. The two commands are essentially the same apart from where Codex runs.

**What it does:** verifies the working tree is in a good state, then requests a review from Codex using the Codex plugin for Claude. When the review is complete, Claude addresses any issues (or pushes back) and requests a new review from Codex. This is repeated up to 7 times because LLMs are nondeterministic and Codex often finds new problems on each cycle. When the review process is complete, Claude creates a PR.

**Highlights:**
* Launches Codex review in a background task, which is useful because I can keep talking to Claude while it's running.
* Prints Codex findings verbatim so I don't have to dig for them.
* Pushes back on Codex findings when they are based on missing information, e.g. outside context Codex doesn't have or trade-offs I discussed with Claude.
* Writes a regression test for each Codex finding (where reasonable). Regressions and re-introducing already-fixed bugs were common occurrences before adding this.
* If Codex finds no issues or keeps finding the same ones, Claude bails before hitting 7 cycles.

**Dependencies:**
* Codex plugin for Claude.
* A ChatGPT account and subscription, depending on usage.

### Command: `session-wrapup`

[View source](commands/session-wrapup.md)

**Why it exists:** Claude will occasionally update its own memory during a session, but this is not enough. A lot of useful information (lessons, workarounds, decisions) gets lost from one session to the next without explicitly saving it somewhere.

**What it does:** Claude reviews the entire session, reads project memory and the project's `CLAUDE.md` file, then suggests what to add, update, or remove.

**Highlights:**
* Filters for signal: lessons learned, architecture decisions, workarounds, and outside context. Not session minutiae.
* Walks docs referenced from `CLAUDE.md`, not just `CLAUDE.md` itself. Those linked docs are usually where drift hides.
* Prunes outdated entries as well as adding new ones, so memory stays trustworthy over time instead of accumulating cruft.

### Skill: `working-with-ignition-designer`

[View source](skills/working-with-ignition-designer)

**Why it exists:** Ignition is a niche industrial automation platform with a relatively small training corpus compared to popular web frameworks. When working in Ignition, Claude will commonly sound confident but get stuck or make mistakes. Additionally, collaboration is a bit trickier compared to software projects because Claude edits files directly while the human uses Designer to edit the same files.

**What it does:** this skill does three things to help Claude work with Ignition better:
1. Provides a growing list of common quirks and gotchas that I've encountered while working with Ignition.
2. Instructs Claude to check Ignition's excellent docs when it's unsure about something or stuck.
3. Provides a debugging framework for Perspective views, which includes a troubleshooting methodology and a headless browser.

The skill also self-improves: when Claude hits a new gotcha that meets the inclusion criteria, it appends it to the gotchas file mid-session.

**Highlights:**
* Borrowed from my web dev background, a Playwright headless driver collapses debugging cycles from ~30-60s of human-driven clicking to ~5s of automated work. Claude observes, acts, and observes again without me touching the browser.
* Strict "one failed attempt = stop and read docs" rule. Prevents the time-consuming guess-and-retry loop that LLMs love to fall into.
* Self-improving with explicit inclusion criteria for new gotchas (recurrence-likely, cross-project applicable, not obvious from docs).
* Enforces a tight feedback loop when debugging. By default, Claude tends to make big batches of changes before verifying, which are hard to debug when something breaks. This skill forces Claude to make small changes and verify at each step. Combined with the Playwright driver, this has allowed Claude to fix problems in minutes that previously took hours.

**Dependencies:**
* Playwright
* Python venv

### Document: Diego's Engineering Guidelines

[View source](templates/diegos-engineering-guidelines.md)

**Why it exists:** Claude does a lot of things well by default, but it also has consistent failure modes: over-engineering small changes, refactoring while fixing bugs, adding error handling for cases that can't happen, writing comments that just restate the code, and so on.
This document is the set of standing rules I want applied on any project I work on (though any project or team can override them), so I don't have to re-explain them every time. Most of them come from nine years of web dev. Each rule traces back to actual mistakes, code reviews, or patterns I've seen in the wild, not abstract principle.

**What it does:** sets stack-agnostic engineering expectations across scope discipline, code quality, building and committing, tests, debugging, security, and "when in doubt." Designed to be referenced from a project's `CLAUDE.md` (e.g. `@.claude/diegos-engineering-guidelines.md`) or pasted in directly. When it conflicts with the project's own `CLAUDE.md`, the project wins.

**Highlights:**
* Written to be applied, not just acknowledged. Every rule is concrete enough that Claude can actually follow it without interpretation.
* Stack-agnostic but web-leaning. Translates cleanly to most of the projects I work on without modification.
* Explicit conflict resolution: project rules override these. The document doesn't pretend to be the ultimate source of truth.
* Grows by addition as I encounter new failure modes worth codifying. Old rules don't go stale because they're principles, not implementation details.

## Tool Usage

My typical workflow for web/software dev:

1. Gather requirements, do preliminary research, create a Todoist task that includes the spec.
2. Start a new Claude Code session and run `/start-todoist-task`.
3. Review the plan and provide feedback if needed. Approve when it's ready.
4. When Claude is done building, run `/manual-qa`.
5. Depending on the nature and size of the work, run `/simplify` (built-in Claude command) and
   `/security-review-plus`.
6. Run `/review-with-codex`.
7. More manual QA if major changes were made during review with Codex.
8. Merge the PR.
9. Run `/session-wrapup`.

## License

MIT, see [LICENSE](LICENSE).