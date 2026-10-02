---
description: Opens the env's PR if needed, merges it once CI is green, deletes the merged branch, tears down the agent environment, and runs /session-wrapup.
argument-hint: "[env-name]"
---

Wrap up an agent environment: get its work merged, then remove the env. Running this command is the user's go-ahead for every step below: opening the PR, merging it once CI passes (a merge can deploy), deleting the merged branch, and tearing the env down. Don't ask again before those; stop only where a step says to.

The steps run scripts in `~/.claude/scripts/environment-wrapup/`. Each script's header documents its output and exit codes, so read it there rather than guessing.

**Scope: one env per run.** That covers every PR the env needs, one per repo it spans: a WordPress env with a sibling plugin has two, both on the same branch. It also covers a new PR from a branch whose earlier PR already merged, while a PR that's already open is reused. PRs from other envs are out of scope: run the command once per env, passing its name.

## 1. Status

From one of the env's worktrees (or from the repo's main checkout, passing the env's name):

```
~/.claude/scripts/environment-wrapup/env-status.sh $ARGUMENTS
```

Note `name`, `main`, `flavor` and each repo's `base` from its JSON. Every later step needs them, and once you leave the env, relative paths point somewhere else.

`base` is where that repo's work merges, and `base_source` says why. Usually it's the default branch. A WordPress env, though, starts from whatever its checkout had checked out, often a long-lived feature branch, and then that branch is the base (`started-from`). Then act on each repo's `action`:

- `create-pr`: open the PR into `base` with your standard, built-in PR-creation workflow; don't restate it here. Two adjustments:
  - Aim each command at the repo's `dir` (`git -C <dir>`, `gh pr create --repo <slug> --head <branch> --base <base>`). This matters for a WordPress sibling, or when you ran the script from the main checkout.
  - Write the PR body to a file in your scratchpad with the Write tool, then pass `--body-file <that file>`. While the session is bound to the worktree, the isolation refuses `$(cat <<EOF ...)`, and any heredoc containing a brace.

  If `merged_prs` isn't empty, an earlier PR from this branch already merged. Before opening the new one, fetch, merge `origin/<base>` into the branch and push, so the new PR shows only the new work. If this session's pre-PR workflow report left findings unfixed, list them in the PR body.
- `merge`: the PR already exists. If `unpushed` > 0, push first (`git -C <dir> push`), or the merge would leave those commits out.
- `cleanup`: the PR (`merged_prs[0]`) already merged, but its remote branch is still there. Step 2 runs on that PR anyway, and only deletes the branch.
- `nothing`: the base already has all of the branch, or the env made no commits in this repo. No PR.
- `unknown-base`: stop. The env started from a commit `base` doesn't have (`started_from`), so a PR into `base` would carry that work too. That commit is either a checkout's unpushed work, or a branch origin doesn't have. When `started_from` is null (git expired the record), the sign is commits that `base` lacks and another branch also has. Ask the user where the work belongs. If it's a branch only on their machine, they need to push it first. Then open the PR into the branch they name; the PR's base is what the scripts follow from then on.
- `multiple-prs`: stop and ask which one to merge.
- `blocked-dirty`: stop. Show `git -C <dir> status --short` and ask what to do with the changes. The pre-PR workflow commits as it goes, so this is unexpected.

If you opened any PR, rerun the script once to confirm every repo now says `merge`, `cleanup` or `nothing`.

## 2. Merge when green

Start one run per `merge` or `cleanup` PR, all at once, each as a background Bash task (`run_in_background: true`, `timeout: 3900000`):

```
~/.claude/scripts/environment-wrapup/merge-when-green.sh <slug> <pr-number>
```

Then wait for the completion notifications; don't poll, sleep or check on them meanwhile. The script waits for CI, merges the commit that passed, and deletes the remote branch. Never merge any other way instead: no `gh pr merge` by hand, no auto-merge, no `--admin`.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | Merged (stdout: merge commit, method, whether the branch was deleted and why not) | Next PR, or step 3 |
| 2 | A check failed (listed with its URL) | Read the failure (`gh run view <run-id> --repo <slug> --log-failed`; the run id is in the URL). If the cause is clear and the fix stays within the PR's scope, fix it in the env, run the relevant tests, commit, push, and rerun the script. Otherwise report and stop. |
| 3 | Timed out (default 60 min) | Report, and ask whether to keep waiting. |
| 4 | The repo normally runs CI, but none started on this PR | Report. Rerun with `--allow-no-checks` only if the user says to. |
| 5 | Not mergeable (the message says why) | Conflicts: fetch, merge `origin/<base>` into the env's branch, resolve, rerun the tests, commit, push, rerun the script. Draft, required review, branch rules or closed: report and stop. |
| 6 | Tool or usage error, or GitHub unreadable five polls in a row | Report and stop. |

Go on to step 3 only once every PR has merged. The env stays in place until then, ready for a fix.

## 3. Leave the env

Which tool depends on how the session got into the env:

- If this session ever called `EnterWorktree`, call `ExitWorktree` with action `keep`. The runtime's worktree isolation stays on until then, invisibly: it survives a compaction and an app restart, so do this even if you can't see the call any more. It's a harmless no-op if you never entered.
- Otherwise the session was moved in with `mcp__ccd_directory__change_directory` (the opt-in flow). Call it with `main`. The move takes effect when the turn ends, so end the turn there and continue from the next one.

This is a directory move, not `git checkout main`: the base branch is already checked out in the main checkout, so checking it out in the worktree fails. Don't `cd` there in Bash either: a hook refuses `cd` into a main checkout from inside an env.

## 4. Tear down

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

## 5. Session wrap-up

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

## 6. Report

End with:

- each PR's link, the branch it merged into (say so when that isn't the default branch), its merge commit, and whether its branch was deleted;
- the teardown result;
- what session-wrapup changed.
