---
name: developing-autocad-extensions
description: Windows only. Build, load, test and debug AutoCAD .NET extensions (plug-ins, add-ins) for AutoCAD 2026 and its toolsets such as AutoCAD Electrical, verifying headlessly with AutoCAD Core Console (accoreconsole). Use whenever work on a Windows machine touches an AutoCAD extension codebase, .NET code that references accoremgd, acdbmgd or acmgd, CommandMethod commands, NETLOAD, trusted locations or SECURELOAD, .scr scripts, AutoLISP glue, DWG automation or plotting from code, even for a quick question. Self-improving: lessons go into gotchas.md as they are learned.
metadata:
  author: Diego Vogel
  version: 0.1.0
---

# Developing AutoCAD extensions

An AutoCAD extension is a .NET assembly loaded into AutoCAD's process. The fast feedback loop is AutoCAD Core Console (`accoreconsole.exe`), AutoCAD without the UI: it runs a script against a drawing in a few seconds, which makes it the Playwright of this world. Full AutoCAD is needed only for UI (dialogs, palettes, ribbon), and the user drives that part.

**Windows only.** .NET extensions and Core Console exist only in AutoCAD for Windows (AutoCAD for Mac can't load .NET extensions), and the runner is a Windows PowerShell 5.1 script, which every Windows machine has. On a Mac there's nothing here to build or run: the skill's files can be read or edited there, but the AutoCAD work happens on Windows.

## Core rules

1. **Read `gotchas.md` before starting.** It holds every non-obvious lesson so far. Skim the headers and read the sections that touch the task.
2. **Pin the target before trusting any guidance.** AutoCAD 2026 is release R25.1 and runs .NET 8 (`net8.0-windows`, x64). AutoCAD 2025 is also .NET 8, 2027 moved to .NET 10, and 2024 and earlier run .NET Framework 4.8. Much of what's online, public agent skills included, targets another release, so check the version before copying a project setting, API call or command-line flag.
3. **Check official docs first, and again after the first failure.** The AutoCAD .NET Developer's Guide and the managed API reference beat forum posts. If the docs don't settle it on the first try, stop guessing and prove the mechanism headlessly (rule 4).
4. **Verify in small increments, headless first.** Use the ladder below. Each new mechanism gets its own minimal probe and its own Core Console run before it's combined with anything else. A passing run licenses only the claim it actually tested.
5. **Never switch off load security.** Don't set SECURELOAD to 0, not even in a test script: it's saved in the AutoCAD profile, so it would turn security off in the user's real AutoCAD too. Stage builds into a trusted dev folder instead (`headless-testing.md`).
6. **Hand UI checks to the user, but keep the verification yours.** No computer control. When something can only be seen in full AutoCAD, give the user a short QA step (format below) and check the evidence they report.
7. **Self-improve mid-session.** When you learn something that meets the bar below, add it to `gotchas.md` right away and tell the user in one line ("Added a gotcha: ..."). Don't save it up for the end.

## Verification ladder

| Rung | Proves | How |
|---|---|---|
| Build | Compiles against the right AutoCAD assemblies, with no new warnings | `dotnet build --no-incremental`, compared with the project's baseline warning count |
| Unit tests | Pure logic | A plain test project. Keep AutoCAD types out of the code under test; they only work inside AutoCAD. |
| In-process tests | Code that needs a live drawing database | NUnit tests run by NUnitLite inside Core Console (`headless-testing.md`, In-process tests) |
| Scripted QA | A command end to end on a real drawing | `scripts/run-core-console.ps1` with a steps file; check printed markers, dumped entities or a plotted PNG |
| User QA | Dialogs, palettes, ribbon, anything that needs the full UI | The user drives full AutoCAD; you write the steps and check their report |

Climb only as high as the change needs, but don't skip a rung the change touches. Say plainly when something wasn't verified.

## User QA handoff

For each step the user runs in full AutoCAD:

- **What you do:** the exact command or clicks, from a stated starting point.
- **Expected:** what they should see.
- **What I check:** evidence you'll verify yourself afterwards (a file, a log line, a dumped entity), so nothing rests on eyeballing alone.

Batch the steps into one round: each round costs an AutoCAD restart, because loaded assemblies can't be unloaded. If rounds get slow, CadAddinManager (a third-party add-in reloader) is the candidate to try; vet it with the user before installing.

## What goes in gotchas.md

Add an entry when it meets at least two of:

- **Likely to recur** in later work.
- **Applies across projects**, not just one codebase.
- **Not obvious from the docs**, or the docs are wrong or silent.

Always skip transient failures (network blips, one-off locks) and quirks of one machine. Quirks of one codebase go in that repo's notes, not here. This skill names no projects, clients or servers.

Format: a one-line tip, or **Symptom / Cause / Fix** for anything that took real debugging, ending with `_Discovered: YYYY-MM-DD_`. File it under the closest section or start a new one. Amend an existing entry rather than adding a near-duplicate, and fix or delete entries that prove wrong.

## Files

- `gotchas.md`: lessons by topic. Read first.
- `headless-testing.md`: the Core Console runner, steps files, staging builds, in-process NUnit tests, plotting to PNG.
- `scripts/run-core-console.ps1`: the runner.
- `scripts/selftest.ps1`: checks that the runner still tells passing runs from failing ones. Run it after changing the runner.

The headless approach draws on Autodesk's ADN-DevTech `acad-api-skill` and `coreconsolerunner` and on `Abo-Eyad/AutoCAD-AccoreConsole-headless` (all MIT), rewritten and retargeted to AutoCAD 2026.

## When this skill does NOT apply

- Drafting by hand in AutoCAD, with no code involved.
- Autodesk Platform Services (cloud APIs, Design Automation): the concepts overlap, but deployment and testing differ.
- Pure AutoLISP or VBA projects: the Core Console tips still help, but the .NET build and load guidance doesn't.
