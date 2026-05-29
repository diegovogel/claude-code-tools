---
name: working-with-ignition-designer
description: "Workflow rules and accumulated lessons for editing Ignition Designer projects (Perspective views, named queries, Jython project scripts, JDBC connections, gateway config). Use when the user mentions Ignition, Inductive Automation, Designer, Perspective, view.json, named query, Jython project script, JDBC connection, ZPL printing, or works in a directory containing an Ignition project (services/ignition/, .gwbk). Read gotchas.md before starting any task; append new lessons mid-session per the criteria below."
metadata:
  author: Diego Lapiduz
  version: "0.1"
---

# Working with Ignition Designer

Ignition is a niche industrial-automation platform with a small training corpus.
The default failure mode of an LLM here is "sound confident, ship nonsense."
This skill exists to compensate for that.

## Core rules

### 1. Read `gotchas.md` before starting any Ignition task

Open the sibling file `gotchas.md` and scan it. Each entry is something you'd
otherwise have to rediscover by debugging. Whatever you're about to do, the
relevant section likely already has the answer.

### 2. Check the official docs when uncertain. Do it first, not after guessing

You hit the docs in two situations:

- **Before** acting, when you're not confident about how something works
  (component event payload, binding shape, sqlType enum, etc.).
- **Immediately after** your first attempt fails. Do NOT enter a guess-and-retry
  loop. One failed attempt = stop, read docs, then try again.

The Ignition docs are at:

```
https://www.docs.inductiveautomation.com/docs/<version>/<topic>
```

To get the version, check whichever of these the project uses:

- **Docker-based projects** — `docker-compose.yml` image tag:
  `image: inductiveautomation/ignition:8.3.4` → use `8.3`.
- **Native-install projects** — the Gateway web UI footer, the splash
  screen, or `curl http://<host>:<port>/StatusPing` and look for the
  `Version=X.Y.Z` field.
- **Anywhere** — `system.util.getVersion()` from the Designer Script
  Console returns the gateway version.

Use the major.minor portion of the version (e.g. `8.3`) in the docs URL. If
you can't determine the version, fall back to a WebSearch for
`Ignition <topic>` — the docs site search ranks well and the most-recent-
looking result is usually right.

The forum (`forum.inductiveautomation.com`) is also high signal for niche
behavior the official docs gloss over. Search before guessing.

WebFetch works fine on both. Don't tell the user you'll "look at the docs later" —
look at them now.

### 2b. If docs/forums don't give a clear answer, DO NOT GUESS — drive the session headless and verify each step

The skill comes with a Playwright-based headless driver. Set it up at the
start of any non-trivial Ignition task (see `headless-debugging.md`). When
docs/forum search comes up empty, or the first attempt at a docs-derived
solution fails, you fall back to **test-driven manual verification, not
guessing**:

1. Form a hypothesis about the smallest possible step that could break.
2. Make a minimal change that exposes that step (add a log line, simplify a
   script to its first line, place a probe).
3. Trigger it headless — one `venv/bin/python` block per cycle, ~5s.
4. Read `system_logs.idb` for the result.
5. Either move forward or refine the hypothesis. Never widen scope before
   the current step is verified.

This applies to **building** too, not just debugging. If you're not
confident about how a Perspective mechanism works (cross-view messaging,
binding propagation, a popup's param wiring, etc.), don't compose three
mechanisms at once and hope it works. Build one piece, prove it works
headless, then add the next piece. Big-bang assemblies are unfixable;
incremental ones isolate the failing step automatically.

Install the driver somewhere convenient under the project (this repo uses
`services/ignition/debug-tools/driver.py`; any path works — adapt to the
repo's conventions). Each cycle is a short Bash invocation:

```bash
venv/bin/python - <<'PY'
from driver import Browser
with Browser() as b:
    b.open("")
    b.click("button:has-text('Edit Molds')")
    print(b.console(level='error'))
PY
```

To pair the headless side with gateway-side observability you read
`system_logs.idb`. Its location depends on the deployment:

- **Docker** — `docker compose cp <service>:/usr/local/bin/ignition/logs/system_logs.idb /tmp/` then `sqlite3`.
- **Native install** — `<Ignition install>/logs/system_logs.idb` directly
  (e.g. `/usr/local/ignition/logs/` on Linux,
  `C:\Program Files\Inductive Automation\Ignition\logs\` on Windows).

With both halves, you have a complete observe→act→observe loop without
ever asking the user to drive the browser. This collapses debugging
cycles from ~30–60s of human-driven work to ~5s of automated work.
_Established: 2026-05-22._

### 3. Direct disk edits are the default — follow the two-step propagation

This rule applies whenever the project is **file-backed** — i.e. the
Perspective project's resources live in a directory you can edit (typical
for repos backed by Docker, IDE-managed projects, or any setup where
`projects/<ProjectName>/` is on disk). For projects edited *only* through
Designer (no on-disk source of truth), skip this and stick to Designer's
GUI flows.

Edit Designer-managed files (`view.json`, `code.py`, `query.sql`, `resource.json`)
directly on disk. Disk is the source of truth in git, and direct edits leave
a clean diff. You just have to push the change through two cache layers to
get it into the running gateway and into Designer:

1. **Gateway scan** — POST `<gateway>/data/api/v1/scan/projects` with an
   API token (see gotchas → "Ignition 8.3 API keys" for setup). Re-reads
   the disk into the gateway's in-memory project model.
2. **Designer update** — Cmd+Shift+U (File → Update Project). Pulls the
   gateway's fresh model into Designer's local cache.

Either step alone is insufficient. See `gotchas.md` → "Two cache layers" for
the exact mechanism, and the "Gateway scan endpoint" entry for the curl.

**When the resource is currently open in Designer**, the user will see a
conflict dialog on Update Project (Designer marks anything open as "locally
dirty," even without edits). Tell them either to pick the gateway version
in the conflict dialog, or right-click → *Revert Changes* on the resource
before Cmd+Shift+U.

**Fall back to paste-into-Designer snippets** when:

- The user has real unsaved changes on the resource (genuine asterisk) that
  shouldn't be discarded.
- The change is structural and easier through Designer's GUI than as JSON
  (column render modes, event subscriptions, etc.).

Otherwise, prefer direct disk edits + the propagation sequence.

### 4. Self-improve the skill mid-session

When you encounter a new lesson that meets the criteria below, **append it to
`gotchas.md` immediately**, then tell the user what you added in one line.
Don't wait until session end — by then it's easy to forget.

#### Criteria for adding a `gotchas.md` entry

Must hit **at least 2 of these 3**:

1. **Recurrence-likely.** This will hit again on this or another Ignition
   project. Tiny pro-tips that recur are valid; one-off issues are not.
2. **Cross-project applicable.** Could occur on any Ignition project, not just
   the one in this repo. (Repo-specific quirks — e.g. "this project's postgres
   user is `dbadmin`" — go in that repo's CLAUDE.md instead.)
3. **Not obvious from docs.** Either the official docs are silent, misleading,
   or the gotcha is a buried-fact you'd miss on first read. If the answer is
   plainly in the docs, the lesson is "read the docs" — don't pollute the list.

Always skip:

- One-off transient failures (network blip, gateway was down, 1Password locked).
- User-machine-specific quirks (shell PATH, browser version).
- Things you'd never run into twice.

#### Format

Entries live under topic sections (View JSON, Bindings, Events, Named Queries,
SQL, Project Scripts, Gateway & Connections, Designer workflow, etc.). Within a
section, use whichever format fits:

- **One-liner pro tip** for small recurring formatting/style rules.
- **Detailed entry** (Symptom / Root cause / Fix) for substantive gotchas.

See `gotchas.md` for examples.

#### Workflow updates

The "Workflow rules" section of `gotchas.md` is amendable the same way as a
gotcha entry. When you learn a better way to interact with Designer / the
gateway / the user, append or revise it.

## When this skill does NOT apply

- Pure backend/database work that doesn't touch Ignition Designer
  (e.g. writing a stored procedure for MSSQL with no Perspective consumer).
  Use repo-level CLAUDE.md guidance instead.
- Ignition module *development* (Java/Kotlin SDK, building `.modl` files).
  Different toolchain, different gotchas. This skill won't help.
