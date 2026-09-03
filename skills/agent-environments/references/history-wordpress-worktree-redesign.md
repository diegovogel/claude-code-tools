# History: the September 2026 WordPress env redesign

Historical reference, condensed from a brainstorm panel, three days of field tests
and an adversarial review (2026-09-02/03). The live rules are in `SKILL.md` and
`references/wordpress.md`; this file records why they are what they are, so the
same ground is not re-dug. The per-hook test suites in `tests/` are the executable
part of this record.

## 1. What happened

A week-long session on the tab-handbook site (theme + plugin in one WordPress
install) could not tear down its own agent env: every `cd <main checkout>` and
`git -C <main checkout>` was refused, and `agent-env-wp.sh list` from inside the
env said the env did not exist. The diagnosis recorded at the time: the runtime
anchors any session whose cwd is a linked worktree, so a worktree-based env can
never be torn down from inside; the proposed fix was "clone, not worktree".

That diagnosis was wrong. The transcript showed the session had called
`EnterWorktree` itself (the pre-PR workflow's step 0), never called
`ExitWorktree`, lost the memory of entering to a context compaction, was re-bound
on every resume, and read the enforcement as structural. On top of that, a real
bug: `repo_root()` used `--show-toplevel`, which inside a worktree returns the
worktree, so the registry lookup landed in an empty directory and the env looked
gone. The fix is `--path-format=absolute --git-common-dir`.

## 2. Probes that overturned the premise

Headless probes on 2026-09-02, verbatim outputs kept at the time:

- A fresh session launched inside a hand-made linked worktree got **no
  enforced isolation**: 13 of 13 commands allowed, including `git -C <main>
  status`, `cd <env root>` and `x=$(git ...)`. The layout only adds a soft
  system-prompt line ("Do NOT cd to the original repository root").
- A fresh session inside a plain clone got no worktree notice at all. A bare
  `rm -rf <own cwd tree>` typed on the command line is a separate guard
  ("Dangerous rm operation detected", a prompt interactively); the same
  deletion inside a script passes, because the runtime reads the command line,
  not the script body.
- An unbound session standing inside its env ran the guarded `destroy` of that
  env. It dropped the DB, removed the worktree, deleted the branch, freed the
  slot and deleted the session's own cwd; Bash recovered to `$HOME` and later
  commands ran from there (relative paths then break, absolute ones work).

So teardown-from-inside already worked for an unbound session, and the whole
"clone" candidate was solving a misdiagnosed problem.

## 3. The panel

`brainstorm-with-panel`: five generators (Codex plus four Claude lenses) produced
39 cards in nine clusters; Codex and a fresh-context Claude evaluated the pool
against the code, the probes and the runtime docs. Both said, independently:
**clones are not the answer; worktrees stay.** They split on what replaces the
failed operation:

- **A. Keep `EnterWorktree`, make `ExitWorktree` a gated first wrap-up step**,
  with a SessionStart hook restoring env identity after compaction (Codex's
  first pick: keeps the runtime's un-disableable net).
- **B. Never bind; move the session with the desktop `change_directory` tool**
  into the theme, the plugin, then back to main for destroy, with path-based
  hooks as the safety net (Claude's first pick: removes the class of binding
  bugs instead of managing it).

Both agreed on the prerequisites: manage the theme and plugin as symmetric
worktrees; derive env identity from the on-disk layout, never from `$PWD` or
memory; a path-based Bash guard for the sibling's main checkout, which the
runtime never protects under any design; sync the drifted project forks.

Clone downsides the evaluators surfaced, kept here so they are not rediscovered:
a CoW copy of a live `.git` is neither atomic nor clean (it inherits the main
checkout's dirty tree, index, reflog, hooks config, worktree registrations and
the env registry itself, a destroy-the-wrong-env hazard); `EnterWorktree` cannot
adopt a clone at all, so clones force the cwd-move mechanism that makes them
redundant; `unique_commits` in a clone counts against stale remote-tracking refs;
Tower shows worktrees nested and automatically, clones only as manual peer
bookmarks; `git branch` in main stops showing env branches; the edit guard goes
inert.

Rejected outright: a runtime-owned lifecycle through `WorktreeCreate` /
`WorktreeRemove` (the remove hook cannot block, so the dirty/unpushed guard goes
silent, and the desktop app is not a documented trigger); deferred teardown by a
daemon, GC or session-end hook (a hand-off in disguise, plus background state);
alternative git topologies and storage models (far from ordinary git for no
remaining problem).

## 4. Field tests in the desktop app

Both approaches were run end to end in one desktop session, with real envs,
through `/compact` and a real app quit + resume. Facts established:

| Fact | Consequence |
|---|---|
| The `EnterWorktree` binding survives `/compact` and an app restart; nothing in the post-compaction context says the session is bound. `ExitWorktree(keep)` lifts it after both. | Any wrap-up that starts with `cd <main>` wedges; the wrap-up command now starts with "leave the env". |
| While bound the runtime refuses: `git -C <main>`, command substitution, `$VAR` in a chained command, brace-bearing heredocs (a PHP file with closures, even into the worktree's own files), heredocs chained with commands, git chained with anything but `add && commit`. Write/Edit bypass it. Only the bound worktree's own parent repo is protected. | Approach A costs one git step per call and a Write-tool detour; the sibling main is unprotected either way. |
| `change_directory` does not bind. It takes effect at turn end and the app asks for folder approval on every move; an allow rule for the tool does not suppress it. | Two prompts per env, in and out, is the floor. |
| Hooks see `CLAUDE_PROJECT_DIR` = the launch directory across compaction and a directory change, but after an app restart of a moved session it equals the env directory (the app relaunches the session where it stood). The compact hook fired every time; the resume hook fired for the moved session and not for the bound one. | Hooks must key on the on-disk layout (the `<site>__<name>` install, gitdir pointers), never on the launch directory. |
| An env's in-tree `scripts/agent-env-wp.sh` is whatever its branch last committed. | Guards that matter must also live in a hook, and script changes must be committed to reach envs. |
| A hand-typed Bash call containing `npx` (even `npx --no-install`) is denied whole by the package-install gate. | Use `node_modules/.bin/<tool>`. |

Both A and B passed. B was chosen first, for its lack of command-shape
friction; the hooks are identical for both. Section 7 records why that was
reversed the next day.

## 5. What was built

- `agent-env-enter-worktree-gate.cjs` refuses `EnterWorktree` into a WordPress
  env; `agent-env-main-guard.cjs` refuses mutations of any main checkout of the
  site from inside an env, including a snapshot-only sibling and `destroy` of
  the env the shell stands in; `worktree-edit-guard.cjs` gained the sibling
  mains; `agent-env-session-context.sh` re-states env, mains, creator and the
  wrap-up rule on every SessionStart source, and covers generic
  `.claude/worktrees/` envs too.
- `agent-env-wp.sh`: `SIBLING_REPOS` and `project_after_worktree`; `destroy`
  guards and reclaims every sibling and refuses to run from under the env
  install; slots, locks and DB claims moved to one machine-wide pool under
  `ENV_PARENT`, with every existing env's `wp-config.php` port counted as taken.
  The generic `agent-env.sh` gained the same in-worktree `destroy` refusal.
- A prototype `agent-env-destroy-gate.cjs` keyed on `cwd != CLAUDE_PROJECT_DIR`
  was retired once the app-restart test showed that signal resets.

The adversarial review of that change set confirmed nine findings, all fixed
and pinned by tests: per-command scans that spanned newlines; destroy spellings
the tripwire missed (quoted paths, `VAR=` and `env`/`nohup` prefixes, `bash -c`);
a lifecycle-script exemption that was a substring bypass; `CLAUDE_PROJECT_DIR`
inside the env being added as a main; docs promising an edit guard for the
sibling main that did not exist; the SessionStart matcher missing `clear`; the
dirty guard applied to a half-built env's CoW snapshot; and the claim that
branches are kept "until merged into origin/main" (the rule is "no commit found
nowhere else").

## 6. Why binding (A) is the default after all

The first day in the field showed the cost of the move-only flow. A session
created its env and called `change_directory`, but a directory move lands only
when the turn ends, and an autonomous run (plan approved, implement, pre-PR
chain) never ends its turn. The session called the tool three times (three
folder prompts, none effective), worked from the main checkout all day, and
compensated with `run <name> --`, `cd` inside single Bash calls and diffs handed
to reviewers by hand; the cwd-reading review skills saw the main checkout until
it did. A sibling session got its move only because its turn happened to end
while review agents ran in the background.

Counted per env, A costs one approval prompt on entry and no turn boundaries
(`EnterWorktree` and `ExitWorktree` keep both take effect immediately, and the
wrap-up runs unattended in one turn); B costs two prompts and two turn
boundaries. The envs exist for unattended work, so binding became the default
on 2026-09-03. Nothing else changed: the hooks, the script refusals and the
sibling worktrees are approach-agnostic, the wrap-up already starts with
`ExitWorktree` keep, and the binding's invisibility is now a loud refusal
instead of a wedge. The price is the bound session's command-shape friction
(one git step per call, Write/Edit for brace-bearing files), accepted as
cheaper than a human in the loop. The EnterWorktree gate stays in the skill,
unwired, as the switch back to the move-only flow.

## 7. Left open

- The resume-hook inconsistency between the two restarts was not explained.
- Whether `wp eval '<inline code>'` is refused while bound was not tested; a
  literal `wp eval-file <path>` passes, contrary to an older claim.
- Machine-wide slots and the Bash guard were not ported to the generic engine;
  the runtime's own isolation is the intended net there. Revisit if the
  command-shape friction of a bound session starts to hurt in Laravel or Node
  work.
