---
description: Tears down an agent environment whose PRs are merged, and runs /session-wrapup.
argument-hint: "[env-name]"
---

The PRs for this environment's work are merged. Wrap up the agent environment. Running this command is the user's go-ahead for every step below: deleting a merged PR's leftover remote branch and tearing the env down. Don't ask again before those; stop only where a step says to. To open and merge the PRs first, use `/land`, which ends by running this command.

The steps run scripts in `~/.claude/scripts/environment-wrapup/`. Each script's header documents its output and exit codes, so read it there rather than guessing.

## 1. Status

From one of the env's worktrees (or from the repo's main checkout, passing the env's name):

```
~/.claude/scripts/environment-wrapup/env-status.sh $ARGUMENTS
```

Note `name`, `main`, `flavor` and each repo's `base` from its JSON. Every later step needs them, and once you leave the env, relative paths point somewhere else. Then act on each repo's `action`:

- `nothing`: the base has everything on the branch, or the env made no commits in this repo. Ready.
- `cleanup`: the PR (`merged_prs[0]`) merged, but its remote branch is still there. Delete it with `~/.claude/scripts/environment-wrapup/merge-when-green.sh <slug> <pr-number>`, which finds the PR already merged and only deletes the branch. Exit 0 means ready, even when it kept the branch (`branch_deleted` false; `branch_note` says why); on any other exit, report and stop.
- `create-pr`, `merge`, `multiple-prs` or `unknown-base`: stop. The work isn't merged yet: report what's unmerged and suggest `/land`, which handles each of these.
- `blocked-dirty`: stop. Show `git -C <dir> status --short` and ask what to do with the changes.

Go on only once every repo is ready.

## 2. Leave the env

If the session isn't in the env (you ran this from the main checkout, passing the env's name), skip to step 3. Otherwise, which tool depends on how the session got into the env:

- If this session ever called `EnterWorktree`, call `ExitWorktree` with action `keep`. The runtime's worktree isolation stays on until then, invisibly: it survives a compaction and an app restart, so do this even if you can't see the call any more. It's a harmless no-op if you never entered.
- Otherwise the session was moved in with `mcp__ccd_directory__change_directory` (the opt-in flow). Call it with `main`. The move takes effect when the turn ends, so end the turn there and continue from the next one.

This is a directory move, not `git checkout main`: the base branch is already checked out in the main checkout, so checking it out in the worktree fails. Don't `cd` there in Bash either: a hook refuses `cd` into a main checkout from inside an env.

## 3. Tear down

For a `lightweight` env (no engine, e.g. a Shopify theme), first stop its dev server (`pkill -f "theme dev.*--port <PORT>"`). Then, from the main checkout:

```
~/.claude/scripts/environment-wrapup/teardown.sh <name> <main>
```

It runs the project's guarded `destroy`, or removes a lightweight env's worktree and branch. A squash or rebase merge rewrites the branch's commits, so the guard refuses; the script then forces the teardown only once it has confirmed the base has everything on the branch. It works out each repo's base the way step 1 did, which after the merge means the merged PR's base.

Last, it fast-forwards each repo's base branch in its main checkout. If someone has another branch checked out there, it updates the base branch without checking it out.

- **Exit 0**: done. Its output says how each base branch was updated.
- **Exit 1**: it refused and removed nothing. Report the reason, and never `--force` a teardown by hand.
- **Exit 6**: error. Report it.

For a Shopify theme, deleting the env's dev theme is optional (the agent-environments skill's `references/shopify.md`).

## 4. Session wrap-up

Run `/session-wrapup`. Its repo edits (memory files under `~/.claude` aren't in the repo) belong on the env's own repo's base branch (the first repo's `base`), and must not touch a person's work. So first check the main checkout:

- `git -C <main> branch --show-current`;
- `git -C <main> status --porcelain`;
- `git -C <main> rev-list --count origin/<base>..<base>`, the commits a push would publish besides yours.

Then:

- **On the base branch, clean, and 0 commits ahead:** make the edits there, commit them, and push.
- **Otherwise** (someone else's branch, their uncommitted changes, or their unpushed commits):
  1. Leave that checkout alone. Make the edits in a temporary worktree instead (this overrides session-wrapup's "edit only the main checkout's copy"): `git -C <main> worktree add --detach <scratchpad>/wrapup-<name> origin/<base>`.
  2. Commit there, and push with `git -C <that worktree> push origin HEAD:<base>`.
  3. Remove it: `git -C <main> worktree remove <that worktree>`.

If pushing to the base branch deploys or triggers something that matters, flag that before pushing.

## 5. Report

End with:

- each leftover branch step 1 handled: deleted, or kept and why (`branch_note`);
- the teardown result;
- what session-wrapup changed.
